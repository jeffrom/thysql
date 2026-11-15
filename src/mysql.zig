const std = @import("std");
const Allocator = std.mem.Allocator;

const C = @import("mysql_c");
const Unicode = @import("unicode.zig");
const Options = @import("options.zig");
const Password = @import("password.zig");
const CsvOutput = @import("csv_output.zig");
const JsonOutput = @import("json_output.zig");

const maxTableColumnDisplayWidth: usize = 1024;
const crServerGoneError: u32 = 2006;
const crServerLostError: u32 = 2013;

/// True when the error means the connection is gone: 2006 (server has gone away)
/// or 2013 (lost connection during a query). The REPL reconnects on these, as mysql.cc does.
pub fn isLostConnection(errno: u32) bool {
    return errno == crServerGoneError or errno == crServerLostError;
}

/// What the last failed connect attempt reported. It is copied out because the
/// handle is closed before the caller can read it.
pub const ConnectFailure = struct {
    errno: u32 = 0,
    message_buffer: [512]u8 = undefined,
    message_len: usize = 0,

    pub fn message(self: *const ConnectFailure) []const u8 {
        return self.message_buffer[0..self.message_len];
    }

    /// Prints the failure as mysql.cc's put_error does. `line` adds the "at line N" suffix that
    /// batch input uses.
    pub fn render(self: *const ConnectFailure, out: *std.Io.Writer, line: ?usize) !void {
        try out.print("ERROR {d} (HY000)", .{self.errno});
        if (line) |number| {
            try out.print(" at line {d}", .{number});
        }
        try out.print(": {s}\n", .{self.message()});
    }

    fn record(self: *ConnectFailure, db: *C.struct_st_mysql) void {
        self.errno = C.mysql_errno(db);
        const text = std.mem.sliceTo(C.mysql_error(db), 0);
        self.message_len = @min(text.len, self.message_buffer.len);
        @memcpy(self.message_buffer[0..self.message_len], text[0..self.message_len]);
    }
};

/// Supplies the password for each connect, so a reconnect gets a fresh one. The DB
/// keeps no password when a provider is set.
pub const PasswordProvider = struct {
    ctx: *anyopaque,
    fetchFn: *const fn (ctx: *anyopaque, target: Password.Target, reason: Password.Reason) anyerror!Password.AuthOutput,
};

pub const DBInfo = struct {
    host: []const u8,
    user: []const u8,
    /// Used only when `password_provider` is null.
    password: []const u8 = "",
    /// When set, the password comes from here on every connect, and `password` is ignored.
    password_provider: ?PasswordProvider = null,
    database: []const u8,
    port: u32 = 3306,
    socket: []const u8 = "",
    protocol: Options.Protocol = .default,
    tls: Options.Tls = .{},
    /// Seconds to wait for the connection to open. 0 keeps the library default.
    connect_timeout: u32 = 0,
    /// Connection fields set on the command line. The auth command's settings may not change them.
    locked: Options.ConnectFieldSet = .{},
    /// Do not print a failed connect to stderr. `thysql complete` sets this unless it is debugging.
    quiet_connect_error: bool = false,
};

/// TLS settings as NUL-terminated strings for the C library. An empty string means unset.
const Tls = struct {
    enabled: bool,
    ca: [:0]const u8,
    capath: [:0]const u8,
    cert: [:0]const u8,
    key: [:0]const u8,
    cipher: [:0]const u8,
    crl: [:0]const u8,
    crlpath: [:0]const u8,
    tls_version: [:0]const u8,
    verify_server_cert: bool,
};

/// Everything `connect` needs. The strings must be NUL-terminated.
const ConnectParams = struct {
    host: [:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    port: u32,
    socket: [:0]const u8,
    protocol: Options.Protocol,
    tls: Tls,
    connect_timeout: u32,
};

/// PasswordFailed means the password provider could not give a password for a connect.
pub const DBError = error{ ExecError, StoreResultError, ConnectError, OutOfMemory, PasswordFailed };

pub const OKResult = struct {
    affected_rows: u64,
    warnings: u32,
    info: ?[]const u8,
};

pub const ExecResult = union(enum) {
    result: [*c]C.struct_st_mysql_res,
    ok: OKResult,
};

pub const DB = struct {
    conn: *C.struct_st_mysql,
    allocator: Allocator,
    /// Owns the socket path and TLS strings, so they live as long as the connection.
    strings: std.heap.ArenaAllocator,
    host: [:0]u8,
    user: [:0]u8,
    password: [:0]u8,
    database: [:0]u8,
    port: u32,
    socket: [:0]const u8,
    protocol: Options.Protocol,
    tls: Tls,
    connect_timeout: u32,
    connect_failure: ConnectFailure = .{},
    password_provider: ?PasswordProvider,
    /// The connection fields before the auth command's settings. Each connect starts from these, and
    /// the fields above are what the last connect used. Strings are owned by `base_strings`.
    base: Options.Options,
    base_strings: std.heap.ArenaAllocator,
    /// Connection fields set on the command line. The auth command's settings may not change them.
    locked: Options.ConnectFieldSet,

    /// Connects as `info` says, and prints a failed connect to stderr unless `info.quiet_connect_error`.
    pub fn init(allocator: Allocator, info: DBInfo) !DB {
        var failure: ConnectFailure = .{};
        return open(allocator, info, &failure) catch |err| {
            if (err == error.ConnectError and !info.quiet_connect_error) {
                std.debug.print("Connect to database failed: {s}\n", .{failure.message()});
            }
            return err;
        };
    }

    /// Connects as `info` says, and prints nothing. A failed connect leaves its error in
    /// `failure`, for `ConnectFailure.render`. The caller closes the DB that it returns.
    pub fn open(allocator: Allocator, info: DBInfo, failure: *ConnectFailure) !DB {
        var base_strings = std.heap.ArenaAllocator.init(allocator);
        errdefer base_strings.deinit();
        const base = try dupeBase(base_strings.allocator(), info);
        // With a provider, the password is fetched for each connect and not kept here.
        const password = try allocator.dupeSentinel(u8, if (info.password_provider == null) info.password else "", 0);
        errdefer allocator.free(password);

        const next = try connectWith(allocator, base, password, info.locked, info.password_provider, .connect, failure);

        return .{
            .conn = next.conn,
            .allocator = allocator,
            .strings = next.strings,
            .host = next.host,
            .user = next.user,
            .password = password,
            .database = next.database,
            .port = next.port,
            .socket = next.socket,
            .protocol = next.protocol,
            .tls = next.tls,
            .connect_timeout = info.connect_timeout,
            .password_provider = info.password_provider,
            .base = base,
            .base_strings = base_strings,
            .locked = info.locked,
        };
    }

    pub fn close(self: *DB) void {
        C.mysql_close(self.conn);
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        self.strings.deinit();
        self.base_strings.deinit();
    }

    fn params(self: *const DB) ConnectParams {
        return .{
            .host = self.host,
            .user = self.user,
            .password = self.password,
            .database = self.database,
            .port = self.port,
            .socket = self.socket,
            .protocol = self.protocol,
            .tls = self.tls,
            .connect_timeout = self.connect_timeout,
        };
    }

    /// Makes `database` the current one. Reconnecting after a lost connection is up to the
    /// caller, so it can print what mysql.cc prints.
    pub fn selectDatabase(self: *DB, database: [:0]const u8) DBError!void {
        if (C.mysql_select_db(self.conn, database.ptr) != 0) {
            return error.ExecError;
        }

        const owned_database = try self.allocator.dupeSentinel(u8, database, 0);
        self.allocator.free(self.database);
        self.database = owned_database;
    }

    /// Runs one statement. It does not reconnect: see `isLostConnection` and `reconnect`.
    pub fn exec(self: *DB, query: []const u8) DBError!ExecResult {
        if (C.mysql_real_query(self.conn, query.ptr, query.len) == 0) {
            return self.currentExecResult();
        }
        return error.ExecError;
    }

    pub fn nextResult(self: *DB) DBError!?ExecResult {
        const status = C.mysql_next_result(self.conn);
        if (status < 0) {
            return null;
        }
        if (status > 0) {
            return DBError.ExecError;
        }

        return try self.currentExecResult();
    }

    fn currentExecResult(self: *DB) DBError!ExecResult {
        const result = self.mysqlStoreResultForLazy() catch return DBError.StoreResultError;
        if (result) |res| {
            return .{ .result = res };
        }

        const info = C.mysql_info(self.conn);
        return .{ .ok = .{
            .affected_rows = C.mysql_affected_rows(self.conn),
            .warnings = C.mysql_warning_count(self.conn),
            .info = if (info == null) null else std.mem.sliceTo(info, 0),
        } };
    }

    fn mysqlStoreResultForLazy(self: *DB) DBError!?[*c]C.struct_st_mysql_res {
        if (C.mysql_store_result(self.conn)) |result| {
            return result;
        }

        const message = C.mysql_error(self.conn);
        if (message != null and message[0] != 0) {
            return DBError.StoreResultError;
        }

        return null;
    }

    pub fn renderLastError(self: *DB, out: *std.Io.Writer) !void {
        const errno = C.mysql_errno(self.conn);
        const sqlstate = C.mysql_sqlstate(self.conn);
        const message = C.mysql_error(self.conn);

        try render_error(out, errno, if (sqlstate == null) null else std.mem.sliceTo(sqlstate, 0), std.mem.sliceTo(message, 0));
    }

    /// Like renderLastError, but with the "at line N" suffix used by batch input.
    pub fn renderLastErrorAt(self: *DB, out: *std.Io.Writer, line: usize) !void {
        const errno = C.mysql_errno(self.conn);
        const sqlstate = C.mysql_sqlstate(self.conn);
        const message = C.mysql_error(self.conn);

        try render_error_at_line(out, errno, if (sqlstate == null) null else std.mem.sliceTo(sqlstate, 0), std.mem.sliceTo(message, 0), line);
    }

    pub fn warningCount(self: *DB) u32 {
        return C.mysql_warning_count(self.conn);
    }

    pub fn lastErrno(self: *DB) u32 {
        return C.mysql_errno(self.conn);
    }

    /// Prints the warnings of the last statement as mysql.cc does: `Warning (Code 1366): text`.
    /// A lone warning with the same code as `error_code` is skipped, because the error was already printed.
    pub fn renderWarnings(self: *DB, out: *std.Io.Writer, error_code: u32) !void {
        const exec_result = self.exec("SHOW WARNINGS") catch return;
        const result = switch (exec_result) {
            .result => |res| res,
            .ok => return,
        };
        defer freeResult(result);

        const count = C.mysql_num_rows(result);
        while (C.mysql_fetch_row(result)) |row| {
            if (row == null) {
                break;
            }
            const lengths = C.mysql_fetch_lengths(result);
            const level = cellText(row, lengths, 0);
            const code = cellText(row, lengths, 1);
            const message = cellText(row, lengths, 2);
            const code_number = std.fmt.parseUnsigned(u32, code, 10) catch 0;
            if (count == 1 and error_code != 0 and code_number == error_code) {
                return;
            }
            try out.print("{s} (Code {s}): {s}\n", .{ level, code, message });
        }
        try out.flush();
    }

    /// Runs `sql` and copies its first row into owned strings. NULL columns are null.
    /// Returns null when the query fails or has no rows. Release it with `freeRowCopy`.
    pub fn firstRowCopy(self: *DB, allocator: Allocator, sql: []const u8) !?[]?[]u8 {
        const exec_result = self.exec(sql) catch return null;
        const result = switch (exec_result) {
            .result => |res| res,
            .ok => return null,
        };
        defer freeResult(result);

        const row = C.mysql_fetch_row(result);
        if (row == null) {
            return null;
        }
        const lengths = C.mysql_fetch_lengths(result);
        const count: usize = C.mysql_num_fields(result);
        const values = try allocator.alloc(?[]u8, count);
        @memset(values, null);
        errdefer freeRowCopy(allocator, values);
        for (values, 0..) |*value, index| {
            if (row[index] == null) {
                continue;
            }
            value.* = try allocator.dupe(u8, row[index][0..lengths[index]]);
        }
        return values;
    }

    /// The TLS cipher in use, or null when the connection is not encrypted.
    pub fn sslCipher(self: *DB) ?[]const u8 {
        const cipher = C.mysql_get_ssl_cipher(self.conn);
        return if (cipher == null) null else std.mem.sliceTo(cipher, 0);
    }

    /// The connection type, such as "127.0.0.1 via TCP/IP".
    pub fn hostInfo(self: *DB) []const u8 {
        const info = C.mysql_get_host_info(self.conn);
        return if (info == null) "" else std.mem.sliceTo(info, 0);
    }

    pub fn protocolVersion(self: *DB) u32 {
        return C.mysql_get_proto_info(self.conn);
    }

    /// The server's status line, as from SHOW STATUS summary, such as "Uptime: 3725  Threads: 2 ...".
    pub fn statLine(self: *DB) ?[]const u8 {
        const stat = C.mysql_stat(self.conn);
        return if (stat == null) null else std.mem.sliceTo(stat, 0);
    }

    pub fn connectionId(self: *DB) u64 {
        return @intCast(C.mysql_thread_id(self.conn));
    }

    pub fn killRunningQuery(self: *DB) DBError!void {
        var failure: ConnectFailure = .{};
        const killer = connect(self.params(), &failure) catch {
            return error.ExecError;
        };
        defer C.mysql_close(killer);

        var command_buffer: [64]u8 = undefined;
        const command = std.fmt.bufPrint(&command_buffer, "KILL QUERY {}", .{self.connectionId()}) catch unreachable;
        if (C.mysql_real_query(killer, command.ptr, command.len) != 0) {
            return error.ExecError;
        }
    }

    pub fn serverName(self: *DB) []const u8 {
        const name = C.mysql_get_server_name(self.conn);
        return if (name == null) "" else std.mem.sliceTo(name, 0);
    }

    pub fn serverVersion(self: *DB) []const u8 {
        const version = C.mysql_get_server_info(self.conn);
        return if (version == null) "" else std.mem.sliceTo(version, 0);
    }

    pub fn renderDatabaseCompletions(self: *DB, out: *std.Io.Writer, prefix: []const u8) DBError!void {
        const exec_result = try self.exec("SHOW DATABASES");
        switch (exec_result) {
            .result => |result| {
                defer freeResult(result);
                while (C.mysql_fetch_row(result)) |row| {
                    if (row == null) {
                        break;
                    }

                    const lengths = C.mysql_fetch_lengths(result);
                    const database = row[0][0..lengths[0]];
                    if (std.mem.startsWith(u8, database, prefix)) {
                        out.print("{s}\n", .{database}) catch return error.ExecError;
                    }
                }
            },
            .ok => {},
        }
        out.flush() catch return error.ExecError;
    }

    /// Opens a new connection with the same settings, as mysql.cc's reconnect does.
    pub fn reconnect(self: *DB) DBError!void {
        return self.connectAs(null, null, .reconnect);
    }

    /// Opens a new connection to `host` and selects `database`. Null keeps the current
    /// value. The old connection stays open when this fails, and the failure is kept
    /// for `renderConnectFailure`.
    pub fn connectTo(self: *DB, database: ?[]const u8, host: ?[]const u8) DBError!void {
        return self.connectAs(database, host, .connect);
    }

    /// `connectTo`, for a connect made for `reason`, which the password provider sees.
    fn connectAs(self: *DB, database: ?[]const u8, host: ?[]const u8, reason: Password.Reason) DBError!void {
        // The database is the one named, else the current one, and the auth command may not change it.
        // A named host is locked for this connect, and it becomes the base for the connects after it.
        var base = self.base;
        base.database = database orelse self.database;
        var locked = self.locked;
        locked.insert(.database);
        if (host) |name| {
            base.host = try self.base_strings.allocator().dupe(u8, name);
            locked.insert(.host);
        }

        const next = connectWith(self.allocator, base, self.password, locked, self.password_provider, reason, &self.connect_failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PasswordFailed => return error.PasswordFailed,
            else => return error.ConnectError,
        };
        C.mysql_close(self.conn);
        self.conn = next.conn;
        self.base.host = base.host;
        self.adopt(next);
    }

    /// Takes the values of a connect that succeeded, and frees the ones they replace.
    fn adopt(self: *DB, next: Connected) void {
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.database);
        self.strings.deinit();
        self.host = next.host;
        self.user = next.user;
        self.database = next.database;
        self.strings = next.strings;
        self.port = next.port;
        self.socket = next.socket;
        self.protocol = next.protocol;
        self.tls = next.tls;
    }

    /// Prints the last failed connect attempt as mysql.cc's put_error does. `line` adds
    /// the "at line N" suffix that batch input uses.
    pub fn renderConnectFailure(self: *DB, out: *std.Io.Writer, line: ?usize) !void {
        try self.connect_failure.render(out, line);
    }

    /// Runs `sql` and copies all of its rows. NULL cells are null. Returns null when the
    /// query fails or returns no rows. Release the result with `freeRowsCopy`.
    pub fn rowsCopy(self: *DB, allocator: Allocator, sql: []const u8) !?[][]?[]u8 {
        const exec_result = self.exec(sql) catch return null;
        const result = switch (exec_result) {
            .result => |res| res,
            .ok => return null,
        };
        defer freeResult(result);

        const count: usize = C.mysql_num_fields(result);
        var rows: std.ArrayList([]?[]u8) = .empty;
        errdefer {
            for (rows.items) |row| freeRowCopy(allocator, row);
            rows.deinit(allocator);
        }
        while (C.mysql_fetch_row(result)) |row| {
            const lengths = C.mysql_fetch_lengths(result);
            const values = try allocator.alloc(?[]u8, count);
            @memset(values, null);
            errdefer freeRowCopy(allocator, values);
            for (values, 0..) |*value, index| {
                if (row[index] == null) {
                    continue;
                }
                value.* = try allocator.dupe(u8, row[index][0..lengths[index]]);
            }
            try rows.append(allocator, values);
        }
        return try rows.toOwnedSlice(allocator);
    }
};

/// Frees the result of `DB.rowsCopy`.
pub fn freeRowsCopy(allocator: Allocator, rows: [][]?[]u8) void {
    for (rows) |row| {
        freeRowCopy(allocator, row);
    }
    allocator.free(rows);
}

/// Copies the TLS options and resolves the verification default: verify when
/// a CA is given, unless the user chose otherwise (as mysql.cc does).
fn dupeTls(allocator: Allocator, tls: Options.Tls) !Tls {
    const has_ca = tls.ca.len > 0 or tls.capath.len > 0;
    return .{
        .enabled = tls.enabled,
        .ca = try allocator.dupeSentinel(u8, tls.ca, 0),
        .capath = try allocator.dupeSentinel(u8, tls.capath, 0),
        .cert = try allocator.dupeSentinel(u8, tls.cert, 0),
        .key = try allocator.dupeSentinel(u8, tls.key, 0),
        .cipher = try allocator.dupeSentinel(u8, tls.cipher, 0),
        .crl = try allocator.dupeSentinel(u8, tls.crl, 0),
        .crlpath = try allocator.dupeSentinel(u8, tls.crlpath, 0),
        .tls_version = try allocator.dupeSentinel(u8, tls.tls_version, 0),
        .verify_server_cert = tls.verify_server_cert orelse has_ca,
    };
}

/// Maps an empty string to NULL, which the C library reads as "not set".
fn optionalCString(value: [:0]const u8) ?[*:0]const u8 {
    return if (value.len == 0) null else value.ptr;
}

/// Sets the protocol and TLS options, as mysql.cc does before mysql_real_connect.
/// Both TLS branches set the posture explicitly rather than relying on library
/// defaults, which differ by host. Verification is set to match TLS use: the
/// library turns TLS on whenever verification is on.
fn applyConnectOptions(db: *C.struct_st_mysql, params: ConnectParams) void {
    switch (params.protocol) {
        .default => {},
        .tcp, .socket => {
            var protocol: c_uint = if (params.protocol == .tcp)
                @intCast(C.MYSQL_PROTOCOL_TCP)
            else
                @intCast(C.MYSQL_PROTOCOL_SOCKET);
            _ = C.mysql_options(db, C.MYSQL_OPT_PROTOCOL, &protocol);
        },
    }

    const tls = params.tls;
    if (!tls.enabled) {
        // Plaintext. Verification must be off as well, or the library turns TLS back on.
        var off: C.my_bool = 0;
        _ = C.mysql_options(db, C.MYSQL_OPT_SSL_ENFORCE, &off);
        _ = C.mysql_options(db, C.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off);
        return;
    }
    // Use TLS when the server offers it. mysql_ssl_set also turns TLS on.
    _ = C.mysql_ssl_set(
        db,
        optionalCString(tls.key),
        optionalCString(tls.cert),
        optionalCString(tls.ca),
        optionalCString(tls.capath),
        optionalCString(tls.cipher),
    );
    _ = C.mysql_options(db, C.MYSQL_OPT_SSL_CRL, optionalCString(tls.crl));
    _ = C.mysql_options(db, C.MYSQL_OPT_SSL_CRLPATH, optionalCString(tls.crlpath));
    _ = C.mysql_options(db, C.MYSQL_OPT_TLS_VERSION, optionalCString(tls.tls_version));
    var verify: C.my_bool = @intFromBool(tls.verify_server_cert);
    _ = C.mysql_options(db, C.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify);
}

/// A connect that succeeded, with the values it used. `host`, `user` and `database` are
/// allocated with the allocator that `connectWith` was given. The rest are in `strings`.
const Connected = struct {
    conn: *C.struct_st_mysql,
    strings: std.heap.ArenaAllocator,
    host: [:0]u8,
    user: [:0]u8,
    database: [:0]u8,
    port: u32,
    socket: [:0]const u8,
    protocol: Options.Protocol,
    tls: Tls,
};

/// Copies the connection fields of `info` into `arena`. The base lives as long as the DB.
fn dupeBase(arena: Allocator, info: DBInfo) !Options.Options {
    return .{
        .host = try arena.dupe(u8, info.host),
        .user = try arena.dupe(u8, info.user),
        .database = try arena.dupe(u8, info.database),
        .port = info.port,
        .socket = try arena.dupe(u8, info.socket),
        .protocol = info.protocol,
        .tls = try dupeOptionsTls(arena, info.tls),
        .connect_timeout = info.connect_timeout,
    };
}

fn dupeOptionsTls(arena: Allocator, tls: Options.Tls) !Options.Tls {
    return .{
        .enabled = tls.enabled,
        .ca = try arena.dupe(u8, tls.ca),
        .capath = try arena.dupe(u8, tls.capath),
        .cert = try arena.dupe(u8, tls.cert),
        .key = try arena.dupe(u8, tls.key),
        .cipher = try arena.dupe(u8, tls.cipher),
        .crl = try arena.dupe(u8, tls.crl),
        .crlpath = try arena.dupe(u8, tls.crlpath),
        .tls_version = try arena.dupe(u8, tls.tls_version),
        .verify_server_cert = tls.verify_server_cert,
    };
}

/// Opens a connection with `base`, the connection fields before the auth command, plus the
/// settings from the provider's auth command for the fields that are not `locked`. With a
/// provider, the password and the settings come from it for this connect only, and the secret
/// is zeroed when this function returns, after the connect attempt. Without one, `password` is
/// used. Any failure to get the password is `error.PasswordFailed`, and the provider has reported
/// it. On failure, `failure` holds the connect error.
fn connectWith(
    allocator: Allocator,
    base: Options.Options,
    password: [:0]const u8,
    locked: Options.ConnectFieldSet,
    provider: ?PasswordProvider,
    reason: Password.Reason,
    failure: *ConnectFailure,
) !Connected {
    var values = base;
    var auth: ?Password.AuthOutput = null;
    defer if (auth) |*output| output.deinit();

    var secret: [:0]const u8 = password;
    if (provider) |source| {
        const target: Password.Target = .{
            .host = base.host,
            .user = base.user,
            .port = base.port,
            .database = base.database,
            .socket = base.socket,
        };
        auth = source.fetchFn(source.ctx, target, reason) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }
            return error.PasswordFailed;
        };
        Password.applySettings(&values, auth.?.settings, locked);
        secret = auth.?.password.bytes;
    }

    // The values are copied before the auth output is freed, so they outlive it.
    var strings = std.heap.ArenaAllocator.init(allocator);
    errdefer strings.deinit();
    const host = try allocator.dupeSentinel(u8, values.host, 0);
    errdefer allocator.free(host);
    const user = try allocator.dupeSentinel(u8, values.user, 0);
    errdefer allocator.free(user);
    const database = try allocator.dupeSentinel(u8, values.database, 0);
    errdefer allocator.free(database);
    const socket = try strings.allocator().dupeSentinel(u8, values.socket, 0);
    const tls = try dupeTls(strings.allocator(), values.tls);

    const conn = try connect(.{
        .host = host,
        .user = user,
        .password = secret,
        .database = database,
        .port = values.port,
        .socket = socket,
        .protocol = values.protocol,
        .tls = tls,
        .connect_timeout = values.connect_timeout,
    }, failure);
    return .{
        .conn = conn,
        .strings = strings,
        .host = host,
        .user = user,
        .database = database,
        .port = values.port,
        .socket = socket,
        .protocol = values.protocol,
        .tls = tls,
    };
}

/// Opens a connection. On failure, `failure` holds the error and the handle is closed.
fn connect(params: ConnectParams, failure: *ConnectFailure) !*C.struct_st_mysql {
    const db = C.mysql_init(null);

    if (db == null) {
        return error.InitError;
    }

    applyConnectOptions(db, params);
    if (params.connect_timeout != 0) {
        var timeout: c_uint = params.connect_timeout;
        _ = C.mysql_options(db, C.MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
    }

    // A socket path only matters for host "localhost" (or no host). The library
    // ignores it for other hosts and for protocol tcp, as it does for mysql.cc.
    const conn_result = C.mysql_real_connect(
        db,
        params.host.ptr,
        params.user.ptr,
        params.password.ptr,
        params.database.ptr,
        params.port,
        optionalCString(params.socket),
        C.CLIENT_MULTI_STATEMENTS,
    );
    if (conn_result == null) {
        failure.record(db);
        C.mysql_close(db);
        return error.ConnectError;
    }

    return db;
}

pub fn freeResult(result: [*c]C.struct_st_mysql_res) void {
    C.mysql_free_result(result);
}

/// A stored result set, as `DB.exec` returns it.
pub const Result = [*c]C.struct_st_mysql_res;

pub fn resultRows(result: Result) u64 {
    return @intCast(C.mysql_num_rows(result));
}

/// Moves a stored result's row cursor back to the first row, so it can be rendered again.
pub fn rewindResult(result: Result) void {
    C.mysql_data_seek(result, 0);
}

/// Sums the field lengths of every row, which is the size `\y` checks against
/// clipboard-max-bytes. The cursor is back on the first row afterwards.
pub fn countFieldBytes(result: Result) u64 {
    const count: usize = C.mysql_num_fields(result);
    var total: u64 = 0;
    rewindResult(result);
    while (C.mysql_fetch_row(result)) |_| {
        const lengths = C.mysql_fetch_lengths(result);
        for (0..count) |index| {
            total += @intCast(lengths[index]);
        }
    }
    rewindResult(result);
    return total;
}

/// Frees a row from `DB.firstRowCopy`.
pub fn freeRowCopy(allocator: Allocator, values: []?[]u8) void {
    for (values) |value| {
        if (value) |text| {
            allocator.free(text);
        }
    }
    allocator.free(values);
}

/// The text of one column of a fetched row. NULL and missing columns read as "".
fn cellText(row: C.MYSQL_ROW, lengths: [*c]c_ulong, index: usize) []const u8 {
    if (row[index] == null) {
        return "";
    }
    return row[index][0..lengths[index]];
}

pub fn clientInfo() []const u8 {
    const info = C.mysql_get_client_info();
    return if (info == null) "" else std.mem.sliceTo(info, 0);
}

pub fn render_ok(out: *std.Io.Writer, ok: OKResult) !void {
    try render_ok_status(out, ok);
    try out.print("\n", .{});
    if (ok.info) |info| {
        try out.print("{s}\n", .{info});
    }
    try out.print("\n", .{});
    try out.flush();
}

pub fn render_ok_timed(out: *std.Io.Writer, ok: OKResult, elapsed_ns: i96) !void {
    try render_ok_status(out, ok);
    try renderElapsed(out, elapsed_ns);
    try out.print("\n", .{});
    if (ok.info) |info| {
        try out.print("{s}\n", .{info});
    }
    try out.print("\n", .{});
    try out.flush();
}

fn render_ok_status(out: *std.Io.Writer, ok: OKResult) !void {
    if (ok.affected_rows == C.MYSQL_COUNT_ERROR) {
        try out.print("Query OK", .{});
    } else {
        try out.print("Query OK, {} {s} affected", .{
            ok.affected_rows,
            if (ok.affected_rows == 1) "row" else "rows",
        });
    }

    try renderWarningCount(out, ok.warnings);
}

fn renderElapsed(out: *std.Io.Writer, elapsed_ns: i96) !void {
    const rounded_ms = @divTrunc(elapsed_ns + @as(i96, std.time.ns_per_ms / 2), std.time.ns_per_ms);
    const seconds = @divTrunc(rounded_ms, 1000);
    const millis = @rem(rounded_ms, 1000);

    try out.print(" ({}.", .{seconds});
    if (millis < 100) {
        try out.print("0", .{});
    }
    if (millis < 10) {
        try out.print("0", .{});
    }
    try out.print("{} sec)", .{millis});
}

pub fn render_error(out: *std.Io.Writer, errno: u32, sqlstate: ?[]const u8, message: []const u8) !void {
    if (errno == 0) {
        try out.print("ERROR: {s}\n", .{message});
    } else if (sqlstate) |state| {
        try out.print("ERROR {} ({s}): {s}\n", .{ errno, state, message });
    } else {
        try out.print("ERROR {}: {s}\n", .{ errno, message });
    }
    try out.flush();
}

/// Error line in the mysql.cc batch format, e.g. `ERROR 1146 (42S02) at line 3: ...`.
pub fn render_error_at_line(out: *std.Io.Writer, errno: u32, sqlstate: ?[]const u8, message: []const u8, line: usize) !void {
    try out.print("ERROR", .{});
    if (errno != 0) {
        try out.print(" {}", .{errno});
        if (sqlstate) |state| {
            try out.print(" ({s})", .{state});
        }
    }
    if (line != 0) {
        try out.print(" at line {}", .{line});
    }
    try out.print(": {s}\n", .{message});
    try out.flush();
}

/// Settings for `renderResultAs`. Each format reads only the fields it needs.
pub const RenderOptions = struct {
    /// Allocates the JSON key names, which need room for renamed duplicate columns.
    allocator: Allocator,
    /// Table, tab and CSV output write the column names first. False for `-N`.
    column_names: bool = true,
    /// Tab output writes values unescaped, as with `-r`.
    raw: bool = false,
    /// Receives one warning per JSON result set that had duplicate column names. Null drops it.
    stderr: ?*std.Io.Writer = null,
    /// NDJSON flushes after each row, so a reader on a pipe sees rows as they arrive.
    flush_rows: bool = false,
    /// JSON prints one member per line, indented, as the REPL does. False is compact.
    pretty: bool = false,
};

/// Renders one result for batch and -e input. As in mysql.cc, table, tab and vertical
/// print nothing for a result with no rows, and there is no footer. A CSV result with no
/// rows and no column names writes nothing. CSV separates result sets with one blank line,
/// so `csv_started` records whether an earlier CSV result set wrote output.
pub fn render_script_result(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, format: Options.ResultFormat, options: RenderOptions, csv_started: *bool) !void {
    const rows = C.mysql_num_rows(result);
    switch (format) {
        .table, .tab, .vertical => {
            if (rows == 0) {
                return;
            }
        },
        .csv => {
            if (rows == 0 and !options.column_names) {
                return;
            }
            if (csv_started.*) {
                try out.writeByte('\n');
            }
            csv_started.* = true;
        },
        .json, .ndjson => {},
    }
    try renderResultAs(out, result, format, options);
}

/// Renders one result set in any format, without a footer and without skipping empty
/// results. `json` writes `[]` for no rows, `ndjson` writes nothing, and `csv` writes
/// only the header. `table`, `tab` and `vertical` keep their own output.
pub fn renderResultAs(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, format: Options.ResultFormat, options: RenderOptions) !void {
    switch (format) {
        .table => try render_result_columns(out, result, options.column_names),
        .tab => try render_result_tab(out, result, options.column_names, options.raw),
        .vertical => try render_result_vertical(out, result),
        .json => try renderJsonArray(out, result, options),
        .ndjson => try renderNdjson(out, result, options),
        .csv => try renderCsv(out, result, options),
    }
}

/// One JSON array of row objects, `[{...},{...}]`, on one line and ending with a newline.
/// With `pretty`, each object is indented on its own lines inside the array.
fn renderJsonArray(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, options: RenderOptions) !void {
    const fields = resultFields(result);
    const keys = try JsonOutput.columnKeys(options.allocator, fields);
    defer keys.deinit(options.allocator);
    try warnRenamedKeys(options, keys.renamed);

    try out.writeByte('[');
    var rowCount: usize = 0;
    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }
        if (rowCount > 0) {
            try out.writeByte(',');
        }
        if (options.pretty) {
            try out.writeAll("\n  ");
            try JsonOutput.writePrettyRowObject(out, keys.names, fields, row, C.mysql_fetch_lengths(result));
        } else {
            try JsonOutput.writeRowObject(out, keys.names, fields, row, C.mysql_fetch_lengths(result));
        }
        rowCount += 1;
    }
    if (options.pretty and rowCount > 0) {
        try out.writeByte('\n');
    }
    try out.writeAll("]\n");
    try out.flush();
}

/// One JSON object per row, each on its own line. An empty result writes nothing.
fn renderNdjson(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, options: RenderOptions) !void {
    const fields = resultFields(result);
    const keys = try JsonOutput.columnKeys(options.allocator, fields);
    defer keys.deinit(options.allocator);
    try warnRenamedKeys(options, keys.renamed);

    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }
        try JsonOutput.writeRowObject(out, keys.names, fields, row, C.mysql_fetch_lengths(result));
        try out.writeByte('\n');
        if (options.flush_rows) {
            try out.flush();
        }
    }
    try out.flush();
}

/// RFC 4180 rows, with the column names on the first line unless `column_names` is false.
fn renderCsv(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, options: RenderOptions) !void {
    const fields = resultFields(result);
    if (options.column_names) {
        try CsvOutput.writeHeader(out, fields);
    }

    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }
        try CsvOutput.writeRow(out, fields, row, C.mysql_fetch_lengths(result));
    }
    try out.flush();
}

/// The result's column descriptions, one per column, in order.
fn resultFields(result: [*c]C.struct_st_mysql_res) []C.struct_st_mysql_field {
    const count: usize = C.mysql_num_fields(result);
    return C.mysql_fetch_fields(result)[0..count];
}

fn warnRenamedKeys(options: RenderOptions, renamed: usize) !void {
    if (renamed == 0) {
        return;
    }
    const stderr = options.stderr orelse return;
    try stderr.print("warning: {} duplicate column name{s} given a suffix in JSON output\n", .{
        renamed,
        if (renamed == 1) "" else "s",
    });
    try stderr.flush();
}

/// Writes a value with the escaping mysql.cc uses for --batch output. With
/// raw, bytes are written unchanged.
fn writeTabValue(out: *std.Io.Writer, value: []const u8, raw: bool) !void {
    if (raw) {
        try out.writeAll(value);
        return;
    }
    for (value) |byte| {
        switch (byte) {
            0 => try out.writeAll("\\0"),
            '\t' => try out.writeAll("\\t"),
            '\n' => try out.writeAll("\\n"),
            '\\' => try out.writeAll("\\\\"),
            else => try out.writeByte(byte),
        }
    }
}

/// Tab-separated rows. Column names are written as-is, as mysql.cc does. NULL is always `NULL`.
pub fn render_result_tab(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, column_names: bool, raw: bool) !void {
    const numFields: usize = C.mysql_num_fields(result);

    if (column_names) {
        _ = C.mysql_field_seek(result, 0);
        for (0..numFields) |i| {
            const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
            if (i > 0) {
                try out.writeByte('\t');
            }
            try out.writeAll(field.*.name[0..field.*.name_length]);
        }
        try out.writeByte('\n');
    }

    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }

        const lengths = C.mysql_fetch_lengths(result);
        for (0..numFields) |i| {
            if (i > 0) {
                try out.writeByte('\t');
            }
            if (row[i] == null) {
                try out.writeAll("NULL");
            } else {
                try writeTabValue(out, row[i][0..lengths[i]], raw);
            }
        }
        try out.writeByte('\n');
    }
    try out.flush();
}

pub fn render_result(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res) !void {
    try render_result_columns(out, result, true);
}

/// Table output. With column_names false the header row is omitted, as with mysql.cc -N.
pub fn render_result_columns(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, column_names: bool) !void {
    const numFields: usize = C.mysql_num_fields(result);

    if (C.mysql_num_rows(result) == 0) {
        try out.print("Empty set\n\n", .{});
        try out.flush();
        return;
    }

    _ = C.mysql_field_seek(result, 0);
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        field.*.max_length = cappedTableWidth(Unicode.escapedDisplayWidth(field.*.name[0..field.*.name_length]));
        if (field.*.max_length < 4 and (field.*.flags & C.NOT_NULL_FLAG) == 0) {
            field.*.max_length = 4;
        }
    }

    if (result.*.data != null) {
        while (C.mysql_fetch_row(result)) |row| {
            if (row == null) {
                break;
            }

            const lengths = C.mysql_fetch_lengths(result);
            _ = C.mysql_field_seek(result, 0);
            for (0..numFields) |i| {
                const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
                const value_width = if (row[i] == null)
                    Unicode.escapedDisplayWidth("NULL")
                else
                    renderedValueDisplayWidth(field, row[i][0..lengths[i]]);
                field.*.max_length = @max(field.*.max_length, cappedTableWidth(value_width));
            }
        }
        C.mysql_data_seek(result, 0);
    }

    _ = C.mysql_field_seek(result, 0);
    try printColumnSeparators(out, result, numFields);
    try out.print("+\n", .{});

    if (column_names) {
        _ = C.mysql_field_seek(result, 0);
        for (0..numFields) |_| {
            const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
            const name = field.*.name[0..field.*.name_length];

            try printHeaderCell(out, name, field.*.max_length);
        }
        try out.print("|\n", .{});

        _ = C.mysql_field_seek(result, 0);
        try printColumnSeparators(out, result, numFields);
        try out.print("+\n", .{});
    }
    try out.flush();

    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }

        const lengths = C.mysql_fetch_lengths(result);

        try printMysqlRow(out, result, row, lengths, numFields);
    }

    _ = C.mysql_field_seek(result, 0);
    try printColumnSeparators(out, result, numFields);
    try out.print("+\n", .{});
    try out.flush();
}

pub fn render_result_timed(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, elapsed_ns: i96) !void {
    try render_result_timed_with_warnings(out, result, elapsed_ns, 0);
}

pub fn render_result_timed_with_warnings(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, elapsed_ns: i96, warnings: u32) !void {
    if (C.mysql_num_rows(result) == 0) {
        try out.print("Empty set", .{});
        try renderWarningCount(out, warnings);
        try renderElapsed(out, elapsed_ns);
        try out.print("\n\n", .{});
        try out.flush();
        return;
    }

    try render_result(out, result);
    try render_result_footer(out, result, elapsed_ns, warnings);
}

pub fn render_result_vertical(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res) !void {
    const numFields: usize = C.mysql_num_fields(result);

    if (C.mysql_num_rows(result) == 0) {
        try out.print("Empty set\n\n", .{});
        try out.flush();
        return;
    }

    _ = C.mysql_field_seek(result, 0);
    var maxNameLength: usize = 0;
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        maxNameLength = @max(maxNameLength, Unicode.escapedDisplayWidth(field.*.name[0..field.*.name_length]));
    }

    C.mysql_data_seek(result, 0);
    var rowCount: usize = 1;
    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }

        try out.print("*************************** {}. row ***************************\n", .{rowCount});

        const lengths = C.mysql_fetch_lengths(result);
        _ = C.mysql_field_seek(result, 0);
        for (0..numFields) |i| {
            const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
            const name = field.*.name[0..field.*.name_length];
            try printPadding(out, maxNameLength - Unicode.escapedDisplayWidth(name));
            try Unicode.printEscapedValue(out, name, std.math.maxInt(usize));
            try out.print(": ", .{});
            if (row[i] == null) {
                try out.print("NULL\n", .{});
            } else if (isBinaryField(field)) {
                try Unicode.printHexValue(out, row[i][0..lengths[i]], std.math.maxInt(usize));
                try out.print("\n", .{});
            } else {
                try Unicode.printEscapedValue(out, row[i][0..lengths[i]], std.math.maxInt(usize));
                try out.print("\n", .{});
            }
        }

        rowCount += 1;
    }
    try out.flush();
}

pub fn render_result_vertical_timed(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, elapsed_ns: i96) !void {
    try render_result_vertical_timed_with_warnings(out, result, elapsed_ns, 0);
}

pub fn render_result_vertical_timed_with_warnings(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, elapsed_ns: i96, warnings: u32) !void {
    if (C.mysql_num_rows(result) == 0) {
        try out.print("Empty set", .{});
        try renderWarningCount(out, warnings);
        try renderElapsed(out, elapsed_ns);
        try out.print("\n\n", .{});
        try out.flush();
        return;
    }

    try render_result_vertical(out, result);
    try out.print("\n", .{});
    try render_result_footer(out, result, elapsed_ns, warnings);
}

/// The footer line after a result set, `N rows in set (time)`, with a blank line after it.
pub fn render_result_footer(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, elapsed_ns: i96, warnings: u32) !void {
    const rows = C.mysql_num_rows(result);
    try out.print("{} {s} in set", .{ rows, if (rows == 1) "row" else "rows" });
    try renderWarningCount(out, warnings);
    try renderElapsed(out, elapsed_ns);
    try out.print("\n\n", .{});
    try out.flush();
}

fn renderWarningCount(out: *std.Io.Writer, warnings: u32) !void {
    if (warnings == 0) {
        return;
    }
    try out.print(", {} warning{s}", .{
        warnings,
        if (warnings == 1) "" else "s",
    });
}

fn printColumnSeparators(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, numFields: usize) !void {
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        try printColumnSeparator(out, field.*.max_length);
    }
}

fn printMysqlRow(
    out: *std.Io.Writer,
    result: [*c]C.struct_st_mysql_res,
    row: C.MYSQL_ROW,
    lengths: [*c]c_ulong,
    numFields: usize,
) !void {
    _ = C.mysql_field_seek(result, 0);
    for (0..numFields) |i| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        // const name = field.*.name[0..field.*.name_length];
        const dataLength = if (row[i] == null) "NULL".len else lengths[i];
        const value = if (row[i] == null) "NULL" else row[i][0..dataLength];

        try printDataCell(out, field, value, field.*.max_length, isNumericType(field.*.type), row[i] == null);
    }
    try out.print("|\n", .{});
}

fn printHeader(out: *std.Io.Writer, column_names: []const []const u8, maxLength: usize) !void {
    for (column_names) |_| {
        try printColumnSeparator(out, maxLength);
    }
    try out.print("+\n", .{});

    for (column_names) |name| {
        try printHeaderCell(out, name, maxLength);
    }
    try out.print("|\n", .{});

    for (column_names) |_| {
        try printColumnSeparator(out, maxLength);
    }
    try out.print("+\n", .{});
}

fn printRow(out: *std.Io.Writer, column_names: []const []const u8, row: []const []const u8, maxLength: usize) !void {
    for (column_names, row) |_, value| {
        const value_width = @min(Unicode.escapedDisplayWidth(value), maxLength);
        try out.printAsciiChar('|', .{});
        try out.printAsciiChar(' ', .{});
        try printPadding(out, if (maxLength >= value_width) maxLength - value_width else 0);
        try Unicode.printEscapedValue(out, value, maxLength);
        try out.printAsciiChar(' ', .{});
    }
    try out.print("|\n", .{});

    for (column_names) |_| {
        try printColumnSeparator(out, maxLength);
    }
    try out.print("+\n", .{});
}

fn printColumnSeparator(out: *std.Io.Writer, len: usize) !void {
    try out.printAsciiChar('+', .{});
    try printRowSeparator(out, len + 2);
}

fn printHeaderCell(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.printAsciiChar('|', .{});
    try out.printAsciiChar(' ', .{});
    const value_width = @min(Unicode.escapedDisplayWidth(value), width);
    try Unicode.printEscapedValue(out, value, width);
    try printPadding(out, if (width >= value_width) width - value_width else 0);
    try out.printAsciiChar(' ', .{});
}

fn printDataCell(out: *std.Io.Writer, field: *C.struct_st_mysql_field, value: []const u8, width: usize, right_align: bool, is_null: bool) !void {
    const value_width = @min(if (is_null) Unicode.escapedDisplayWidth(value) else renderedValueDisplayWidth(field, value), width);
    try out.printAsciiChar('|', .{});
    try out.printAsciiChar(' ', .{});
    if (right_align) {
        try printPadding(out, if (width >= value_width) width - value_width else 0);
        if (is_null) {
            try Unicode.printEscapedValue(out, value, width);
        } else {
            try printRenderedValue(out, field, value, width);
        }
    } else {
        if (is_null) {
            try Unicode.printEscapedValue(out, value, width);
        } else {
            try printRenderedValue(out, field, value, width);
        }
        try printPadding(out, if (width >= value_width) width - value_width else 0);
    }
    try out.printAsciiChar(' ', .{});
}

fn cappedTableWidth(width: usize) usize {
    return @min(width, maxTableColumnDisplayWidth);
}

fn renderedValueDisplayWidth(field: *C.struct_st_mysql_field, value: []const u8) usize {
    if (isBinaryField(field)) {
        return Unicode.hexDisplayWidth(value);
    }
    return Unicode.escapedDisplayWidth(value);
}

fn printRenderedValue(out: *std.Io.Writer, field: *C.struct_st_mysql_field, value: []const u8, max_width: usize) !void {
    if (isBinaryField(field)) {
        try Unicode.printHexValue(out, value, max_width);
    } else {
        try Unicode.printEscapedValue(out, value, max_width);
    }
}

fn isNumericType(kind: C.enum_enum_field_types) bool {
    return (kind <= C.MYSQL_TYPE_INT24 and kind != C.MYSQL_TYPE_TIMESTAMP) or
        kind == C.MYSQL_TYPE_YEAR or
        kind == C.MYSQL_TYPE_NEWDECIMAL;
}

fn isBinaryField(field: *C.struct_st_mysql_field) bool {
    if (field.*.charsetnr != 63) {
        return false;
    }
    return field.*.type == C.MYSQL_TYPE_BIT or
        field.*.type == C.MYSQL_TYPE_BLOB or
        field.*.type == C.MYSQL_TYPE_LONG_BLOB or
        field.*.type == C.MYSQL_TYPE_MEDIUM_BLOB or
        field.*.type == C.MYSQL_TYPE_TINY_BLOB or
        field.*.type == C.MYSQL_TYPE_VAR_STRING or
        field.*.type == C.MYSQL_TYPE_STRING or
        field.*.type == C.MYSQL_TYPE_VARCHAR or
        field.*.type == C.MYSQL_TYPE_GEOMETRY;
}

fn printRowSeparator(out: *std.Io.Writer, len: usize) !void {
    for (0..len) |_| {
        try out.printAsciiChar('-', .{});
    }
}

fn printPadding(out: *std.Io.Writer, len: usize) !void {
    for (0..len) |_| {
        try out.printAsciiChar(' ', .{});
    }
}

fn serializeType(kind: u32, col: [*:0]const u8) ![*:0]const u8 {
    if (col == null) {
        return "NULL";
    }
    switch (kind) {
        8 => {
            return col;
        },
        else => {
            @panic("unhandled mysql data type");
        },
    }
    return "";
}

pub fn mysqlFieldWithFlags(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types, flags: c_uint) C.struct_st_mysql_field {
    var field: C.struct_st_mysql_field = std.mem.zeroes(C.struct_st_mysql_field);
    field.name = @constCast(name);
    field.length = @intCast(max_length);
    field.max_length = @intCast(max_length);
    field.name_length = @intCast(std.mem.len(name));
    field.flags = flags;
    field.type = kind;
    return field;
}

pub fn mysqlField(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types) C.struct_st_mysql_field {
    return mysqlFieldWithFlags(name, max_length, kind, C.NOT_NULL_FLAG);
}

pub fn mysqlBinaryField(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types) C.struct_st_mysql_field {
    var field = mysqlField(name, max_length, kind);
    field.charsetnr = 63;
    return field;
}

const MysqlRowStorage1 = extern struct {
    values: [2][*c]u8,
    bytes: [32]u8,
    lengths: [1]c_ulong,
};

const MysqlRowStorage2 = extern struct {
    values: [3][*c]u8,
    bytes: [24]u8,
    lengths: [2]c_ulong,
};

const MysqlRowStorage3 = extern struct {
    values: [4][*c]u8,
    bytes: [48]u8,
    lengths: [3]c_ulong,
};

const MysqlRowStorageLarge = extern struct {
    values: [2][*c]u8,
    bytes: [maxTableColumnDisplayWidth + 16]u8,
    lengths: [1]c_ulong,
};

// Test-only row fixtures. libmariadb's stored-result mysql_fetch_lengths()
// derives lengths from adjacent MYSQL_ROW value pointers, so these fixtures
// keep contiguous row bytes plus one extra end pointer. They must be initialized
// in place; returning them by value would leave value pointers aimed at a
// temporary copy.
fn initMysqlRowStorage1(storage: *MysqlRowStorage1, value: ?[]const u8) void {
    storage.* = .{
        .values = .{ null, null },
        .bytes = @splat(0),
        .lengths = .{0},
    };
    if (value) |bytes| {
        std.debug.assert(bytes.len + 1 <= storage.bytes.len);
        @memcpy(storage.bytes[0..bytes.len], bytes);
        storage.values[0] = &storage.bytes[0];
        storage.values[1] = &storage.bytes[bytes.len + 1];
    } else {
        storage.values[1] = &storage.bytes[0];
    }
}

fn initMysqlRowStorageLarge(storage: *MysqlRowStorageLarge, value: []const u8) void {
    storage.* = .{
        .values = .{ null, null },
        .bytes = @splat(0),
        .lengths = .{0},
    };
    std.debug.assert(value.len + 1 <= storage.bytes.len);
    @memcpy(storage.bytes[0..value.len], value);
    storage.values[0] = &storage.bytes[0];
    storage.values[1] = &storage.bytes[value.len + 1];
}

fn initMysqlRowStorage2(storage: *MysqlRowStorage2, value1: []const u8, value2: []const u8) void {
    storage.* = .{
        .values = .{ null, null, null },
        .bytes = @splat(0),
        .lengths = .{ 0, 0 },
    };
    const value2Offset = value1.len + 1;
    const endOffset = value2Offset + value2.len + 1;
    std.debug.assert(endOffset <= storage.bytes.len);
    @memcpy(storage.bytes[0..value1.len], value1);
    @memcpy(storage.bytes[value2Offset..][0..value2.len], value2);
    storage.values[0] = &storage.bytes[0];
    storage.values[1] = &storage.bytes[value2Offset];
    storage.values[2] = &storage.bytes[endOffset];
}

fn initMysqlRowStorage3(storage: *MysqlRowStorage3, value1: []const u8, value2: []const u8, value3: ?[]const u8) void {
    storage.* = .{
        .values = .{ null, null, null, null },
        .bytes = @splat(0),
        .lengths = .{ 0, 0, 0 },
    };

    var offset: usize = 0;
    @memcpy(storage.bytes[offset..][0..value1.len], value1);
    storage.values[0] = &storage.bytes[offset];
    offset += value1.len + 1;

    @memcpy(storage.bytes[offset..][0..value2.len], value2);
    storage.values[1] = &storage.bytes[offset];
    offset += value2.len + 1;

    if (value3) |bytes| {
        @memcpy(storage.bytes[offset..][0..bytes.len], bytes);
        storage.values[2] = &storage.bytes[offset];
        offset += bytes.len + 1;
    } else {
        storage.values[2] = null;
    }

    std.debug.assert(offset < storage.bytes.len);
    storage.values[3] = &storage.bytes[offset];
}

fn mysqlRow(storage: anytype, next: [*c]C.struct_st_mysql_rows) C.struct_st_mysql_rows {
    var row: C.struct_st_mysql_rows = std.mem.zeroes(C.struct_st_mysql_rows);
    row.next = next;
    row.data = &storage.values;
    var length: c_ulong = 0;
    for (storage.lengths) |field_length| {
        length += field_length;
    }
    row.length = length;
    return row;
}

fn mysqlData(first_row: [*c]C.struct_st_mysql_rows, row_count: usize, field_count: usize) C.struct_st_mysql_data {
    var data: C.struct_st_mysql_data = std.mem.zeroes(C.struct_st_mysql_data);
    data.data = first_row;
    data.rows = @intCast(row_count);
    data.fields = @intCast(field_count);
    return data;
}

fn mysqlResult(fields: []C.struct_st_mysql_field, data: *C.struct_st_mysql_data, lengths: [*c]c_ulong) C.struct_st_mysql_res {
    var result: C.struct_st_mysql_res = std.mem.zeroes(C.struct_st_mysql_res);
    result.row_count = data.rows;
    result.field_count = @intCast(fields.len);
    result.fields = fields.ptr;
    result.data = data;
    result.data_cursor = data.data;
    result.lengths = lengths;
    return result;
}

fn expectRendered(result: *C.struct_st_mysql_res, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_result(&writer.writer, result);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedVertical(result: *C.struct_st_mysql_res, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_result_vertical(&writer.writer, result);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedTimed(result: *C.struct_st_mysql_res, elapsed_ns: i96, expect: []const u8) !void {
    try expectRenderedTimedWithWarnings(result, elapsed_ns, 0, expect);
}

fn expectRenderedTimedWithWarnings(result: *C.struct_st_mysql_res, elapsed_ns: i96, warnings: u32, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_result_timed_with_warnings(&writer.writer, result, elapsed_ns, warnings);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedVerticalTimed(result: *C.struct_st_mysql_res, elapsed_ns: i96, expect: []const u8) !void {
    try expectRenderedVerticalTimedWithWarnings(result, elapsed_ns, 0, expect);
}

fn expectRenderedVerticalTimedWithWarnings(result: *C.struct_st_mysql_res, elapsed_ns: i96, warnings: u32, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_result_vertical_timed_with_warnings(&writer.writer, result, elapsed_ns, warnings);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedOk(ok: OKResult, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_ok(&writer.writer, ok);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedOkTimed(ok: OKResult, elapsed_ns: i96, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_ok_timed(&writer.writer, ok, elapsed_ns);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedError(errno: u32, sqlstate: ?[]const u8, message: []const u8, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_error(&writer.writer, errno, sqlstate, message);

    try std.testing.expectEqualStrings(expect, writer.written());
}

test "render SQL error" {
    try expectRenderedError(1064, "42000", "You have an error in your SQL syntax",
        \\ERROR 1064 (42000): You have an error in your SQL syntax
        \\
    );
}

test "lost connection means server gone (2006) or lost during query (2013)" {
    try std.testing.expect(isLostConnection(2006));
    try std.testing.expect(isLostConnection(2013));
    try std.testing.expect(!isLostConnection(1064));
    try std.testing.expect(!isLostConnection(1927));
    try std.testing.expect(!isLostConnection(0));
}

test "a connect failure keeps the message and error number" {
    var failure: ConnectFailure = .{};
    try std.testing.expectEqualStrings("", failure.message());
    const text = "Can't connect to MySQL server on '127.0.0.1' (111)";
    failure.message_len = text.len;
    @memcpy(failure.message_buffer[0..text.len], text);
    failure.errno = 2003;
    try std.testing.expectEqualStrings(text, failure.message());
}

test "render query OK with affected rows" {
    try expectRenderedOk(.{
        .affected_rows = 2,
        .warnings = 0,
        .info = null,
    },
        \\Query OK, 2 rows affected
        \\
        \\
    );
}

test "render timed query OK with affected rows" {
    try expectRenderedOkTimed(.{
        .affected_rows = 2,
        .warnings = 0,
        .info = null,
    }, 2 * std.time.ns_per_ms,
        \\Query OK, 2 rows affected (0.002 sec)
        \\
        \\
    );
}

test "render query OK singular affected row with warnings and info" {
    try expectRenderedOk(.{
        .affected_rows = 1,
        .warnings = 1,
        .info = "Rows matched: 1  Changed: 1  Warnings: 1",
    },
        \\Query OK, 1 row affected, 1 warning
        \\Rows matched: 1  Changed: 1  Warnings: 1
        \\
        \\
    );
}

test "render empty result set" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{0};
    var result = mysqlResult(&fields, &data, &lengths);

    const expect =
        \\Empty set
        \\
        \\
    ;
    try expectRendered(&result, expect);
}

test "render timed empty result set" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{0};
    var result = mysqlResult(&fields, &data, &lengths);

    const expect =
        \\Empty set (0.002 sec)
        \\
        \\
    ;
    try expectRenderedTimed(&result, 2 * std.time.ns_per_ms, expect);
}

test "render timed empty result set with warnings" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{0};
    var result = mysqlResult(&fields, &data, &lengths);

    const expect =
        \\Empty set, 2 warnings (0.002 sec)
        \\
        \\
    ;
    try expectRenderedTimedWithWarnings(&result, 2 * std.time.ns_per_ms, 2, expect);
}

fn expectRenderedScript(result: *C.struct_st_mysql_res, format: Options.ResultFormat, column_names: bool, raw: bool, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();
    var csv_started = false;

    try render_script_result(&writer.writer, result, format, .{ .allocator = gpa, .column_names = column_names, .raw = raw }, &csv_started);

    try std.testing.expectEqualStrings(expect, writer.written());
}

/// Counts the flushes made on it and keeps the bytes written, for checking when rows are flushed.
const FlushCountingWriter = struct {
    interface: std.Io.Writer,
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    flushes: usize = 0,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };

    fn init(gpa: Allocator) FlushCountingWriter {
        return .{ .interface = .{ .vtable = &vtable, .buffer = &.{} }, .gpa = gpa };
    }

    fn deinit(self: *FlushCountingWriter) void {
        self.bytes.deinit(self.gpa);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FlushCountingWriter = @alignCast(@fieldParentPtr("interface", w));
        var consumed: usize = 0;
        for (data, 0..) |bytes, index| {
            const repeat = if (index + 1 == data.len) splat else 1;
            for (0..repeat) |_| {
                self.bytes.appendSlice(self.gpa, bytes) catch return error.WriteFailed;
                consumed += bytes.len;
            }
        }
        return consumed;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FlushCountingWriter = @alignCast(@fieldParentPtr("interface", w));
        self.flushes += 1;
    }
};

test "tab output escapes values, writes NULL, and keeps names" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("a", 1, C.MYSQL_TYPE_VAR_STRING),
        mysqlField("b", 1, C.MYSQL_TYPE_VAR_STRING),
        mysqlField("c", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "x\ty", "p\\q\nr", null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    try expectRenderedScript(&result, .tab, true, false, "a\tb\tc\nx\\ty\tp\\\\q\\nr\tNULL\n");
}

test "tab output without names and raw values" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("a", 1, C.MYSQL_TYPE_VAR_STRING),
        mysqlField("b", 1, C.MYSQL_TYPE_VAR_STRING),
        mysqlField("c", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "x\ty", "p\\q\nr", null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    try expectRenderedScript(&result, .tab, false, false, "x\\ty\tp\\\\q\\nr\tNULL\n");
    _ = C.mysql_data_seek(&result, 0);
    try expectRenderedScript(&result, .tab, true, true, "a\tb\tc\nx\ty\tp\\q\nr\tNULL\n");
}

test "script output prints nothing for an empty result" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{0};
    var result = mysqlResult(&fields, &data, &lengths);

    try expectRenderedScript(&result, .table, true, false, "");
    try expectRenderedScript(&result, .tab, true, false, "");
    try expectRenderedScript(&result, .vertical, true, false, "");
}

test "script output writes json [] and csv header for an empty result, and nothing for ndjson" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
        mysqlField("two", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{ 0, 0 };
    var result = mysqlResult(&fields, &data, &lengths);

    try expectRenderedScript(&result, .json, true, false, "[]\n");
    try expectRenderedScript(&result, .ndjson, true, false, "");
    try expectRenderedScript(&result, .csv, true, false, "1,two\n");
    try expectRenderedScript(&result, .csv, false, false, "");
}

test "script csv separates result sets with one blank line and skips empty results without names" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("a", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);
    var empty_data = mysqlData(null, 0, fields.len);
    var empty_lengths = [_]c_ulong{0};
    var empty = mysqlResult(&fields, &empty_data, &empty_lengths);

    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();
    var csv_started = false;
    const options: RenderOptions = .{ .allocator = gpa };
    const no_names: RenderOptions = .{ .allocator = gpa, .column_names = false };

    try render_script_result(&writer.writer, &result, .csv, options, &csv_started);
    try render_script_result(&writer.writer, &empty, .csv, no_names, &csv_started);
    _ = C.mysql_data_seek(&result, 0);
    try render_script_result(&writer.writer, &result, .csv, options, &csv_started);

    try std.testing.expectEqualStrings("a\n1\n\na\n1\n", writer.written());
}

test "script ndjson flushes after each row only when asked" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONGLONG),
    };
    var row2_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row2_storage, "2");
    var row1_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row1_storage, "1");
    var row2 = mysqlRow(&row2_storage, null);
    var row1 = mysqlRow(&row1_storage, &row2);
    var data = mysqlData(&row1, 2, fields.len);
    var result = mysqlResult(&fields, &data, &row1_storage.lengths);

    const gpa = std.testing.allocator;
    var quiet = FlushCountingWriter.init(gpa);
    defer quiet.deinit();
    var csv_started = false;
    try render_script_result(&quiet.interface, &result, .ndjson, .{ .allocator = gpa }, &csv_started);
    try std.testing.expectEqualStrings("{\"id\":1}\n{\"id\":2}\n", quiet.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), quiet.flushes);

    _ = C.mysql_data_seek(&result, 0);
    var flushing = FlushCountingWriter.init(gpa);
    defer flushing.deinit();
    try render_script_result(&flushing.interface, &result, .ndjson, .{ .allocator = gpa, .flush_rows = true }, &csv_started);
    try std.testing.expectEqualStrings("{\"id\":1}\n{\"id\":2}\n", flushing.bytes.items);
    try std.testing.expectEqual(@as(usize, 3), flushing.flushes);
}

test "table output without column names omits the header" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    try expectRenderedScript(&result, .table, false, false,
        \\+---+
        \\| 1 |
        \\+---+
        \\
    );
}

fn expectRenderedAs(result: *C.struct_st_mysql_res, format: Options.ResultFormat, options: RenderOptions, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try renderResultAs(&writer.writer, result, format, options);

    try std.testing.expectEqualStrings(expect, writer.written());
}

test "renderResultAs writes json as one array and [] when empty" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONGLONG),
        mysqlField("name", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row2_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row2_storage, "2", "grace, rear admiral");
    var row1_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row1_storage, "1", "ada");
    var row2 = mysqlRow(&row2_storage, null);
    var row1 = mysqlRow(&row1_storage, &row2);
    var data = mysqlData(&row1, 2, fields.len);
    var result = mysqlResult(&fields, &data, &row1_storage.lengths);

    try expectRenderedAs(&result, .json, .{ .allocator = std.testing.allocator },
        \\[{"id":1,"name":"ada"},{"id":2,"name":"grace, rear admiral"}]
        \\
    );

    var empty_data = mysqlData(null, 0, fields.len);
    var empty_lengths = [_]c_ulong{0};
    var empty = mysqlResult(&fields, &empty_data, &empty_lengths);
    try expectRenderedAs(&empty, .json, .{ .allocator = std.testing.allocator }, "[]\n");
}

test "renderResultAs writes pretty json with one member per line" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONGLONG),
        mysqlField("name", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row2_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row2_storage, "2", "grace");
    var row1_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row1_storage, "1", "ada");
    var row2 = mysqlRow(&row2_storage, null);
    var row1 = mysqlRow(&row1_storage, &row2);
    var data = mysqlData(&row1, 2, fields.len);
    var result = mysqlResult(&fields, &data, &row1_storage.lengths);

    try expectRenderedAs(&result, .json, .{ .allocator = std.testing.allocator, .pretty = true },
        \\[
        \\  {
        \\    "id": 1,
        \\    "name": "ada"
        \\  },
        \\  {
        \\    "id": 2,
        \\    "name": "grace"
        \\  }
        \\]
        \\
    );

    var empty_data = mysqlData(null, 0, fields.len);
    var empty_lengths = [_]c_ulong{0};
    var empty = mysqlResult(&fields, &empty_data, &empty_lengths);
    try expectRenderedAs(&empty, .json, .{ .allocator = std.testing.allocator, .pretty = true }, "[]\n");
}

test "renderResultAs writes ndjson with one object per line and nothing when empty" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONGLONG),
        mysqlBinaryField("blob", 1, C.MYSQL_TYPE_BLOB),
        mysqlField("n", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "1", "f", null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    try expectRenderedAs(&result, .ndjson, .{ .allocator = std.testing.allocator },
        \\{"id":1,"blob":"Zg==","n":null}
        \\
    );

    var empty_data = mysqlData(null, 0, fields.len);
    var empty_lengths = [_]c_ulong{0};
    var empty = mysqlResult(&fields, &empty_data, &empty_lengths);
    try expectRenderedAs(&empty, .ndjson, .{ .allocator = std.testing.allocator }, "");
}

test "renderResultAs writes csv with a header, quoting, NULL and empty strings" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("a", 1, C.MYSQL_TYPE_VAR_STRING),
        mysqlField("b", 1, C.MYSQL_TYPE_VAR_STRING),
        mysqlField("c", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "x,y", "", null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    try expectRenderedAs(&result, .csv, .{ .allocator = std.testing.allocator },
        \\a,b,c
        \\"x,y","",
        \\
    );
    _ = C.mysql_data_seek(&result, 0);
    try expectRenderedAs(&result, .csv, .{ .allocator = std.testing.allocator, .column_names = false },
        \\"x,y","",
        \\
    );
}

test "renderResultAs csv writes only the header for an empty result" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
        mysqlField("two", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{ 0, 0 };
    var result = mysqlResult(&fields, &data, &lengths);

    try expectRenderedAs(&result, .csv, .{ .allocator = std.testing.allocator }, "1,two\n");
    try expectRenderedAs(&result, .csv, .{ .allocator = std.testing.allocator, .column_names = false }, "");
}

test "renderResultAs json suffixes duplicate names and warns once per result set" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("a", 1, C.MYSQL_TYPE_LONG),
        mysqlField("a", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "1", "2");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const gpa = std.testing.allocator;
    var warn_buf: std.ArrayList(u8) = .empty;
    defer warn_buf.deinit(gpa);
    var warn_writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &warn_buf);
    defer warn_buf = warn_writer.toArrayList();

    try expectRenderedAs(&result, .ndjson, .{ .allocator = gpa, .stderr = &warn_writer.writer },
        \\{"a":1,"a_2":2}
        \\
    );
    try std.testing.expectEqualStrings("warning: 1 duplicate column name given a suffix in JSON output\n", warn_writer.written());
}

test "renderResultAs keeps table, tab and vertical output for empty results" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{0};
    var result = mysqlResult(&fields, &data, &lengths);

    try expectRenderedAs(&result, .table, .{ .allocator = std.testing.allocator }, "Empty set\n\n");
    try expectRenderedAs(&result, .tab, .{ .allocator = std.testing.allocator }, "1\n");
    try expectRenderedAs(&result, .vertical, .{ .allocator = std.testing.allocator }, "Empty set\n\n");
}

test "batch error line has the mysql.cc at-line format" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try render_error_at_line(&writer.writer, 1146, "42S02", "Table 'x.y' doesn't exist", 3);
    try render_error_at_line(&writer.writer, 1064, null, "bad", 0);
    try std.testing.expectEqualStrings(
        \\ERROR 1146 (42S02) at line 3: Table 'x.y' doesn't exist
        \\ERROR 1064: bad
        \\
    , writer.written());
}

test "writeTabValue escapes tab, newline, backslash, and NUL" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeTabValue(&writer.writer, "a\tb\nc\\d\x00e", false);
    try std.testing.expectEqualStrings("a\\tb\\nc\\\\d\\0e", writer.written());
}

test "render SELECT 1" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\+---+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render SELECT 1 with timed footer" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\+---+
        \\1 row in set (0.002 sec)
        \\
        \\
    ;
    try expectRenderedTimed(&result, 2 * std.time.ns_per_ms, expect);
}

test "render SELECT 1 with timed footer and warning" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\+---+
        \\1 row in set, 1 warning (0.002 sec)
        \\
        \\
    ;
    try expectRenderedTimedWithWarnings(&result, 2 * std.time.ns_per_ms, 1, expect);
}

test "render SELECT 1 AS one" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("one", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+-----+
        \\| one |
        \\+-----+
        \\|   1 |
        \\+-----+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render SELECT 1 AS one, 'two' AS two vertically" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("one", 1, C.MYSQL_TYPE_LONG),
        mysqlField("two", 3, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "1", "two");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\*************************** 1. row ***************************
        \\one: 1
        \\two: two
        \\
    ;
    try expectRenderedVertical(&result, expect);
}

test "render SELECT 1 AS one, 'two' AS two vertically with timed footer" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("one", 1, C.MYSQL_TYPE_LONG),
        mysqlField("two", 3, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "1", "two");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\*************************** 1. row ***************************
        \\one: 1
        \\two: two
        \\
        \\1 row in set (0.002 sec)
        \\
        \\
    ;
    try expectRenderedVerticalTimed(&result, 2 * std.time.ns_per_ms, expect);
}

test "render vertical result with timed footer and warnings" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("one", 1, C.MYSQL_TYPE_LONG),
        mysqlField("two", 3, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "1", "two");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\*************************** 1. row ***************************
        \\one: 1
        \\two: two
        \\
        \\1 row in set, 2 warnings (0.002 sec)
        \\
        \\
    ;
    try expectRenderedVerticalTimedWithWarnings(&result, 2 * std.time.ns_per_ms, 2, expect);
}

test "render mixed multi-column table spacing" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONG),
        mysqlField("name", 0, C.MYSQL_TYPE_VAR_STRING),
        mysqlFieldWithFlags("note", 0, C.MYSQL_TYPE_VAR_STRING, 0),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "7", "Ada", null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+----+------+------+
        \\| id | name | note |
        \\+----+------+------+
        \\|  7 | Ada  | NULL |
        \\+----+------+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render numeric edge types right aligned" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("dec", 0, C.MYSQL_TYPE_NEWDECIMAL),
        mysqlField("flt", 0, C.MYSQL_TYPE_FLOAT),
        mysqlField("yr", 0, C.MYSQL_TYPE_YEAR),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "-1.25", "3.5", "2026");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+-------+-----+------+
        \\| dec   | flt | yr   |
        \\+-------+-----+------+
        \\| -1.25 | 3.5 | 2026 |
        \\+-------+-----+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render negative integer and double right aligned" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("big", 0, C.MYSQL_TYPE_LONGLONG),
        mysqlField("dbl", 0, C.MYSQL_TYPE_DOUBLE),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "-42", "123.75");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+-----+--------+
        \\| big | dbl    |
        \\+-----+--------+
        \\| -42 | 123.75 |
        \\+-----+--------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render timestamp values left aligned" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("ts", 0, C.MYSQL_TYPE_TIMESTAMP),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "2026-06-21 10:11:12");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+---------------------+
        \\| ts                  |
        \\+---------------------+
        \\| 2026-06-21 10:11:12 |
        \\+---------------------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render multi-column table uses widest row value" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONG),
        mysqlField("name", 0, C.MYSQL_TYPE_VAR_STRING),
        mysqlFieldWithFlags("note", 0, C.MYSQL_TYPE_VAR_STRING, 0),
    };
    var row2_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row2_storage, "12", "Grace", "ok");
    var row1_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row1_storage, "7", "Ada", null);
    var row2 = mysqlRow(&row2_storage, null);
    var row1 = mysqlRow(&row1_storage, &row2);
    var data = mysqlData(&row1, 2, fields.len);
    var result = mysqlResult(&fields, &data, &row1_storage.lengths);

    const expect =
        \\+----+-------+------+
        \\| id | name  | note |
        \\+----+-------+------+
        \\|  7 | Ada   | NULL |
        \\| 12 | Grace | ok   |
        \\+----+-------+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render nullable metadata reserves NULL width without NULL rows" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("id", 1, C.MYSQL_TYPE_LONG),
        mysqlFieldWithFlags("n", 0, C.MYSQL_TYPE_VAR_STRING, 0),
        mysqlField("tag", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage3 = undefined;
    initMysqlRowStorage3(&row_storage, "7", "x", "ok");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+----+------+-----+
        \\| id | n    | tag |
        \\+----+------+-----+
        \\|  7 | x    | ok  |
        \\+----+------+-----+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render nullable numeric metadata reserves NULL width without NULL rows" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlFieldWithFlags("n", 0, C.MYSQL_TYPE_LONG, 0),
        mysqlField("label", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "3", "ok");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+-------+
        \\| n    | label |
        \\+------+-------+
        \\|    3 | ok    |
        \\+------+-------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render SELECT 'one' AS '1'" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "one");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+-----+
        \\| 1   |
        \\+-----+
        \\| one |
        \\+-----+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render string cells left aligned" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("word", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "x");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| word |
        \\+------+
        \\| x    |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render text controls as escaped table data" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("txt", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    const bytes = [_]u8{ 'a', 0, 'b', '\n', 'c', '\t', 0x1b };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, &bytes);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+---------------+
        \\| txt           |
        \\+---------------+
        \\| a\0b\nc\t\x1B |
        \\+---------------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render invalid UTF-8 text bytes as hex escapes" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("bad", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    const bytes = [_]u8{0xff};
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, &bytes);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| bad  |
        \\+------+
        \\| \xFF |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render binary field as hex" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlBinaryField("blob", 0, C.MYSQL_TYPE_BLOB),
    };
    const bytes = [_]u8{ 0, 1, 0xff };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, &bytes);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+----------+
        \\| blob     |
        \\+----------+
        \\| 0x0001FF |
        \\+----------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render table caps very wide values" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("v", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    const long_width = maxTableColumnDisplayWidth + 8;
    var long_value: [long_width]u8 = @splat('a');
    var row_storage: MysqlRowStorageLarge = undefined;
    initMysqlRowStorageLarge(&row_storage, &long_value);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const gpa = std.testing.allocator;
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &expected);
    defer expected = writer.toArrayList();

    try writer.writer.print("+", .{});
    for (0..maxTableColumnDisplayWidth + 2) |_| {
        try writer.writer.print("-", .{});
    }
    try writer.writer.print("+\n| v", .{});
    for (0..maxTableColumnDisplayWidth - 1) |_| {
        try writer.writer.print(" ", .{});
    }
    try writer.writer.print(" |\n+", .{});
    for (0..maxTableColumnDisplayWidth + 2) |_| {
        try writer.writer.print("-", .{});
    }
    try writer.writer.print("+\n| ", .{});
    for (0..maxTableColumnDisplayWidth) |_| {
        try writer.writer.print("a", .{});
    }
    try writer.writer.print(" |\n+", .{});
    for (0..maxTableColumnDisplayWidth + 2) |_| {
        try writer.writer.print("-", .{});
    }
    try writer.writer.print("+\n", .{});

    try expectRendered(&result, writer.written());
}

test "render accented table using display width" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("word", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "é");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| word |
        \\+------+
        \\| é    |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render decomposed accent table using display width" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("word", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "e\u{301}");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| word |
        \\+------+
        \\| é    |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render CJK table using display width" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("city", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "東京");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| city |
        \\+------+
        \\| 東京 |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render nullable column leaves room for NULL" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlFieldWithFlags("n", 0, C.MYSQL_TYPE_VAR_STRING, 0),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| n    |
        \\+------+
        \\| NULL |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render multiple rows with one bottom border" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row2_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row2_storage, "2");
    var row1_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row1_storage, "1");
    var row2 = mysqlRow(&row2_storage, null);
    var row1 = mysqlRow(&row1_storage, &row2);
    var data = mysqlData(&row1, 2, fields.len);
    var result = mysqlResult(&fields, &data, &row1_storage.lengths);

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\| 2 |
        \\+---+
        \\
    ;
    try expectRendered(&result, expect);
}
