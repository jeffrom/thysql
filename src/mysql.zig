const std = @import("std");
const Allocator = std.mem.Allocator;

const C = @import("mysql_c");
const Unicode = @import("unicode.zig");

const maxTableColumnDisplayWidth: usize = 1024;
const crServerGoneError: u32 = 2006;

pub const DBInfo = struct {
    host: []const u8,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    port: u32 = 3306,
};

pub const DBError = error{ ExecError, StoreResultError, OutOfMemory };

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
    host: [:0]u8,
    user: [:0]u8,
    password: [:0]u8,
    database: [:0]u8,
    port: u32,

    pub fn init(allocator: Allocator, info: DBInfo) !DB {
        const host = try allocator.dupeSentinel(u8, info.host, 0);
        errdefer allocator.free(host);
        const user = try allocator.dupeSentinel(u8, info.user, 0);
        errdefer allocator.free(user);
        const password = try allocator.dupeSentinel(u8, info.password, 0);
        errdefer allocator.free(password);
        const database = try allocator.dupeSentinel(u8, info.database, 0);
        errdefer allocator.free(database);

        const db = try connect(host, user, password, database, info.port);

        return .{
            .conn = db,
            .allocator = allocator,
            .host = host,
            .user = user,
            .password = password,
            .database = database,
            .port = info.port,
        };
    }

    pub fn close(self: *DB) void {
        C.mysql_close(self.conn);
        self.allocator.free(self.host);
        self.allocator.free(self.user);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
    }

    pub fn selectDatabase(self: *DB, database: [:0]const u8) DBError!void {
        if (C.mysql_select_db(self.conn, database.ptr) != 0) {
            if (C.mysql_errno(self.conn) != crServerGoneError) {
                return error.ExecError;
            }
            try self.reconnect();
            if (C.mysql_select_db(self.conn, database.ptr) != 0) {
                return error.ExecError;
            }
        }

        const owned_database = try self.allocator.dupeSentinel(u8, database, 0);
        self.allocator.free(self.database);
        self.database = owned_database;
    }

    pub fn exec(self: *DB, query: []const u8) DBError!ExecResult {
        var retry: usize = 0;
        while (true) : (retry += 1) {
            if (C.mysql_real_query(self.conn, query.ptr, query.len) == 0) {
                return self.currentExecResult();
            }

            const errno = C.mysql_errno(self.conn);
            if (!shouldReconnectAfterQueryError(errno, retry)) {
                return error.ExecError;
            }
            try self.reconnect();
        }
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

    pub fn warningCount(self: *DB) u32 {
        return C.mysql_warning_count(self.conn);
    }

    pub fn connectionId(self: *DB) u64 {
        return @intCast(C.mysql_thread_id(self.conn));
    }

    pub fn killRunningQuery(self: *DB) DBError!void {
        const killer = connect(self.host, self.user, self.password, self.database, self.port) catch {
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

    fn reconnect(self: *DB) DBError!void {
        const db = connect(self.host, self.user, self.password, self.database, self.port) catch {
            return error.ExecError;
        };
        C.mysql_close(self.conn);
        self.conn = db;
    }
};

fn connect(host: [:0]const u8, user: [:0]const u8, password: [:0]const u8, database: [:0]const u8, port: u32) !*C.struct_st_mysql {
    const db = C.mysql_init(null);

    if (db == null) {
        return error.InitError;
    }

    const conn_result = C.mysql_real_connect(
        db,
        host,
        user,
        password,
        database,
        port,
        null,
        C.CLIENT_MULTI_STATEMENTS,
    );
    if (conn_result == null) {
        std.debug.print("Connect to database failed: {s}\n", .{C.mysql_error(db)});
        C.mysql_close(db);
        return error.ConnectError;
    }

    return db;
}

fn shouldReconnectAfterQueryError(errno: u32, retry: usize) bool {
    return errno == crServerGoneError and retry <= 1;
}

pub fn freeResult(result: [*c]C.struct_st_mysql_res) void {
    C.mysql_free_result(result);
}

pub fn affectedRows(ok: OKResult) ?u64 {
    return if (ok.affected_rows == C.MYSQL_COUNT_ERROR) null else ok.affected_rows;
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

pub fn render_result(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res) !void {
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

fn render_result_footer(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, elapsed_ns: i96, warnings: u32) !void {
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

fn mysqlFieldWithFlags(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types, flags: c_uint) C.struct_st_mysql_field {
    var field: C.struct_st_mysql_field = std.mem.zeroes(C.struct_st_mysql_field);
    field.name = @constCast(name);
    field.length = @intCast(max_length);
    field.max_length = @intCast(max_length);
    field.name_length = @intCast(std.mem.len(name));
    field.flags = flags;
    field.type = kind;
    return field;
}

fn mysqlField(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types) C.struct_st_mysql_field {
    return mysqlFieldWithFlags(name, max_length, kind, C.NOT_NULL_FLAG);
}

fn mysqlBinaryField(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types) C.struct_st_mysql_field {
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

test "reconnect retry decision follows server gone errors" {
    try std.testing.expect(shouldReconnectAfterQueryError(crServerGoneError, 0));
    try std.testing.expect(shouldReconnectAfterQueryError(crServerGoneError, 1));
    try std.testing.expect(!shouldReconnectAfterQueryError(crServerGoneError, 2));
    try std.testing.expect(!shouldReconnectAfterQueryError(2013, 0));
    try std.testing.expect(!shouldReconnectAfterQueryError(1064, 0));
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
