//! Command-line options. Every flag is one entry in `specs`; the parser maps a
//! matched entry to an `Id`, and `apply` stores its effect in `Options`.
//! To add a flag: add an `Id`, add a `Spec`, and add a case to `apply`.
//! `renderUsage` is generated from `specs`, so help stays in sync.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Batch = @import("batch.zig");

pub const Error = error{
    MissingOptionValue,
    InvalidPort,
    InvalidDelimiter,
    TooManyDatabases,
    UnknownOption,
    UnexpectedOptionValue,
    PasswordOnCommandLine,
    InvalidProtocol,
    InvalidBoolValue,
    OutOfMemory,
};

pub const ResultFormat = enum { table, tab, vertical };

/// How to reach the server. `default` lets the library choose: a socket for
/// host "localhost", TCP otherwise. -P selects tcp and -S selects socket.
pub const Protocol = enum { default, tcp, socket };

pub const Id = enum {
    host,
    database,
    port,
    user,
    password,
    socket,
    protocol,
    ssl,
    skip_ssl,
    ssl_ca,
    ssl_capath,
    ssl_cert,
    ssl_key,
    ssl_cipher,
    ssl_crl,
    ssl_crlpath,
    tls_version,
    ssl_verify_server_cert,
    skip_ssl_verify_server_cert,
    execute,
    force,
    delimiter,
    batch,
    table,
    vertical,
    raw,
    silent,
    skip_column_names,
    column_names,
    pager,
    tee,
    show_warnings,
    help,
    version,
};

pub const ArgKind = enum { none, required, optional };

pub const Group = enum { connection, execution, output, other };

pub const Spec = struct {
    id: Id,
    long: []const u8,
    short: ?u8 = null,
    arg: ArgKind = .none,
    arg_name: []const u8 = "",
    group: Group,
    help: []const u8,
};

pub const specs = [_]Spec{
    .{ .id = .host, .long = "host", .short = 'h', .arg = .required, .arg_name = "name", .group = .connection, .help = "Connect to host. Defaults to $MARIADB_HOST, $MYSQL_HOST, then localhost." },
    .{ .id = .database, .long = "database", .short = 'D', .arg = .required, .arg_name = "name", .group = .connection, .help = "Database to use." },
    .{ .id = .port, .long = "port", .short = 'P', .arg = .required, .arg_name = "#", .group = .connection, .help = "Port number. Defaults to $MYSQL_TCP_PORT, then 3306. Selects TCP." },
    .{ .id = .user, .long = "user", .short = 'u', .arg = .required, .arg_name = "name", .group = .connection, .help = "User for login. Defaults to $USER when set." },
    .{ .id = .password, .long = "password", .short = 'p', .arg = .optional, .group = .connection, .help = "Prompt for password without echoing input." },
    .{ .id = .socket, .long = "socket", .short = 'S', .arg = .required, .arg_name = "path", .group = .connection, .help = "Unix socket file to use. Selects the socket protocol." },
    .{ .id = .protocol, .long = "protocol", .arg = .required, .arg_name = "name", .group = .connection, .help = "Connection protocol: tcp or socket. Socket applies only to host localhost." },
    .{ .id = .ssl, .long = "ssl", .arg = .optional, .group = .connection, .help = "Use TLS when the server offers it. This is the default." },
    .{ .id = .skip_ssl, .long = "skip-ssl", .group = .connection, .help = "Do not use TLS." },
    .{ .id = .ssl_ca, .long = "ssl-ca", .arg = .required, .arg_name = "file", .group = .connection, .help = "CA certificate file in PEM format. Implies --ssl." },
    .{ .id = .ssl_capath, .long = "ssl-capath", .arg = .required, .arg_name = "dir", .group = .connection, .help = "Directory of CA certificates in PEM format. Implies --ssl." },
    .{ .id = .ssl_cert, .long = "ssl-cert", .arg = .required, .arg_name = "file", .group = .connection, .help = "Client certificate file in PEM format. Implies --ssl." },
    .{ .id = .ssl_key, .long = "ssl-key", .arg = .required, .arg_name = "file", .group = .connection, .help = "Client private key file in PEM format. Implies --ssl." },
    .{ .id = .ssl_cipher, .long = "ssl-cipher", .arg = .required, .arg_name = "list", .group = .connection, .help = "TLS cipher list. Implies --ssl." },
    .{ .id = .ssl_crl, .long = "ssl-crl", .arg = .required, .arg_name = "file", .group = .connection, .help = "Certificate revocation list file. Implies --ssl." },
    .{ .id = .ssl_crlpath, .long = "ssl-crlpath", .arg = .required, .arg_name = "dir", .group = .connection, .help = "Directory of certificate revocation lists. Implies --ssl." },
    .{ .id = .tls_version, .long = "tls-version", .arg = .required, .arg_name = "list", .group = .connection, .help = "TLS protocol versions to allow, such as TLSv1.2,TLSv1.3. Implies --ssl." },
    .{ .id = .ssl_verify_server_cert, .long = "ssl-verify-server-cert", .arg = .optional, .group = .connection, .help = "Verify the server certificate. Takes 1 or 0. Verifies by default when --ssl-ca or --ssl-capath is given." },
    .{ .id = .skip_ssl_verify_server_cert, .long = "skip-ssl-verify-server-cert", .group = .connection, .help = "Do not verify the server certificate, even when a CA is given." },
    .{ .id = .execute, .long = "execute", .short = 'e', .arg = .required, .arg_name = "sql", .group = .execution, .help = "Run the statements and exit. Implies batch mode. Repeat to add more." },
    .{ .id = .delimiter, .long = "delimiter", .arg = .required, .arg_name = "str", .group = .execution, .help = "Statement delimiter for batch and REPL input. Defaults to ';'." },
    .{ .id = .force, .long = "force", .short = 'f', .group = .execution, .help = "Keep going after SQL errors in batch and -e mode." },
    .{ .id = .batch, .long = "batch", .short = 'B', .group = .output, .help = "Tab-separated output with no footers. Implied when stdin is not a terminal." },
    .{ .id = .table, .long = "table", .short = 't', .group = .output, .help = "Table output, even in batch mode." },
    .{ .id = .vertical, .long = "vertical", .short = 'E', .group = .output, .help = "Print every row vertically." },
    .{ .id = .skip_column_names, .long = "skip-column-names", .short = 'N', .group = .output, .help = "Don't write column names in results." },
    .{ .id = .column_names, .long = "column-names", .group = .output, .help = "Write column names in results. This is the default." },
    .{ .id = .silent, .long = "silent", .short = 's', .group = .output, .help = "Tab-separated results. Give -s twice to also omit column names." },
    .{ .id = .raw, .long = "raw", .short = 'r', .group = .output, .help = "Write tab-separated fields without escaping." },
    .{ .id = .pager, .long = "pager", .arg = .optional, .arg_name = "command", .group = .output, .help = "Print results through this shell command. With no command, uses $PAGER. Interactive only." },
    .{ .id = .tee, .long = "tee", .arg = .required, .arg_name = "file", .group = .output, .help = "Append all output to this file. Interactive only." },
    .{ .id = .show_warnings, .long = "show-warnings", .group = .output, .help = "Show warnings after every statement." },
    .{ .id = .help, .long = "help", .short = '?', .group = .other, .help = "Display this help and exit." },
    .{ .id = .version, .long = "version", .short = 'V', .group = .other, .help = "Output version information and exit." },
};

const group_titles = [_]struct { group: Group, title: []const u8 }{
    .{ .group = .connection, .title = "Connection options:" },
    .{ .group = .execution, .title = "Execution options:" },
    .{ .group = .output, .title = "Output options:" },
    .{ .group = .other, .title = "Help and version:" },
};

/// TLS settings. As in mysql.cc, TLS is used when the server offers it, a path
/// option implies --ssl, and --skip-ssl turns TLS off. The last of these flags wins.
pub const Tls = struct {
    enabled: bool = true,
    ca: []const u8 = "",
    capath: []const u8 = "",
    cert: []const u8 = "",
    key: []const u8 = "",
    cipher: []const u8 = "",
    crl: []const u8 = "",
    crlpath: []const u8 = "",
    tls_version: []const u8 = "",
    /// null means "verify when a CA is given", as mysql.cc does. Otherwise
    /// the server certificate is not verified.
    verify_server_cert: ?bool = null,
};

pub const Options = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    password: []const u8 = "",
    database: []const u8 = "",
    port: u32 = 3306,
    prompt_password: bool = false,
    socket: []const u8 = "",
    protocol: Protocol = .default,
    tls: Tls = .{},
    execute: ?std.ArrayList(u8) = null,
    force: bool = false,
    /// Delimiter for batch and REPL input. Checked when it is set.
    delimiter: []const u8 = ";",
    batch: bool = false,
    table: bool = false,
    vertical: bool = false,
    raw: bool = false,
    column_names: bool = true,
    /// Number of explicit -s flags.
    silent: u8 = 0,
    /// From --pager. Null when not given, empty when given without a command.
    pager: ?[]const u8 = null,
    /// From --tee. Null when not given.
    tee: ?[]const u8 = null,
    show_warnings: bool = false,
    show_help: bool = false,
    show_version: bool = false,

    pub fn deinit(self: *Options, allocator: Allocator) void {
        if (self.execute) |*text| {
            text.deinit(allocator);
        }
        self.execute = null;
    }

    /// The -e statements joined by newlines, or null when -e was not given.
    pub fn executeText(self: *const Options) ?[]const u8 {
        return if (self.execute) |text| text.items else null;
    }

    /// Batch mode suppresses footers and uses the batch error format.
    pub fn isBatch(self: *const Options, stdin_is_tty: bool) bool {
        return self.batch or self.execute != null or !stdin_is_tty;
    }

    /// Picks the output format for one statement's result. A trailing \G
    /// always means vertical. Tab output is the default in batch mode (-B, -e, or non-tty
    /// input) and with -s, as mysql.cc sets status.batch for -e.
    pub fn resultFormat(self: *const Options, stdin_is_tty: bool, query_vertical: bool) ResultFormat {
        if (query_vertical or self.vertical) {
            return .vertical;
        }
        const tab_output = self.isBatch(stdin_is_tty) or self.silent > 0;
        return if (tab_output and !self.table) .tab else .table;
    }

    /// As in mysql.cc, -ss hides column names in tab output only. Table output keeps them.
    pub fn showColumnNames(self: *const Options, format: ResultFormat) bool {
        if (!self.column_names) {
            return false;
        }
        return format != .tab or self.silent < 2;
    }
};

fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    return env.get(name);
}

fn defaultPort(env: *const std.process.Environ.Map) Error!u32 {
    const value = envValue(env, "MYSQL_TCP_PORT") orelse return 3306;
    return parsePort(value);
}

fn parsePort(value: []const u8) Error!u32 {
    return std.fmt.parseUnsigned(u32, value, 10) catch Error.InvalidPort;
}

fn defaultOptions(env: *const std.process.Environ.Map) Error!Options {
    return .{
        .host = envValue(env, "MARIADB_HOST") orelse envValue(env, "MYSQL_HOST") orelse "localhost",
        .user = envValue(env, "USER") orelse "",
        .password = envValue(env, "MYSQL_PWD") orelse "",
        .port = try defaultPort(env),
    };
}

/// Parses argv (args[0] is the program name). The caller must call `deinit`
/// on the result.
pub fn parse(allocator: Allocator, args: []const []const u8, env: *const std.process.Environ.Map) Error!Options {
    var options = try defaultOptions(env);
    errdefer options.deinit(allocator);

    var seen_database = false;
    var positional_only = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (positional_only or arg.len < 2 or arg[0] != '-') {
            try setPositionalDatabase(&options, &seen_database, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try parseLong(allocator, &options, args, &i, arg[2..]);
        } else {
            try parseShortCluster(allocator, &options, args, &i, arg[1..]);
        }
    }

    return options;
}

fn setPositionalDatabase(options: *Options, seen_database: *bool, database: []const u8) Error!void {
    if (seen_database.*) {
        return Error.TooManyDatabases;
    }
    seen_database.* = true;
    options.database = database;
}

fn findLong(name: []const u8) ?Spec {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.long, name)) {
            return spec;
        }
    }
    return null;
}

fn findShort(flag: u8) ?Spec {
    for (specs) |spec| {
        if (spec.short == flag) {
            return spec;
        }
    }
    return null;
}

fn parseLong(allocator: Allocator, options: *Options, args: []const []const u8, index: *usize, body: []const u8) Error!void {
    const eq_index = std.mem.indexOfScalar(u8, body, '=');
    const name = if (eq_index) |idx| body[0..idx] else body;
    const spec = findLong(name) orelse return Error.UnknownOption;
    const inline_value = if (eq_index) |idx| body[idx + 1 ..] else null;
    const value = try argumentValue(spec, args, index, inline_value);
    try apply(allocator, options, spec.id, value);
}

/// Handles a cluster of short flags such as `-sNE` or `-hlocalhost`. A flag
/// that takes a value ends the cluster.
fn parseShortCluster(allocator: Allocator, options: *Options, args: []const []const u8, index: *usize, cluster: []const u8) Error!void {
    for (cluster, 0..) |flag, pos| {
        const spec = findShort(flag) orelse return Error.UnknownOption;
        if (spec.arg == .none) {
            try apply(allocator, options, spec.id, null);
            continue;
        }

        const rest = cluster[pos + 1 ..];
        const inline_value: ?[]const u8 = if (rest.len > 0) rest else null;
        const value = try argumentValue(spec, args, index, inline_value);
        try apply(allocator, options, spec.id, value);
        return;
    }
}

/// Returns the value for a matched spec. Optional values are only taken
/// inline, so `-p db` leaves `db` as a positional argument.
fn argumentValue(spec: Spec, args: []const []const u8, index: *usize, inline_value: ?[]const u8) Error!?[]const u8 {
    switch (spec.arg) {
        .none => {
            if (inline_value != null) {
                return Error.UnexpectedOptionValue;
            }
            return null;
        },
        .optional => return inline_value,
        .required => {
            if (inline_value) |value| {
                return value;
            }
            index.* += 1;
            if (index.* >= args.len) {
                return Error.MissingOptionValue;
            }
            return args[index.*];
        },
    }
}

fn requiredValue(value: ?[]const u8) Error![]const u8 {
    return value orelse Error.MissingOptionValue;
}

fn delimiterValue(value: ?[]const u8) Error![]const u8 {
    const text = try requiredValue(value);
    _ = Batch.checkDelimiter(text) catch return Error.InvalidDelimiter;
    return text;
}

/// As in mysql.cc, an empty value means "not set" and anything but tcp or socket is rejected.
fn protocolValue(value: ?[]const u8) Error!Protocol {
    const text = try requiredValue(value);
    if (text.len == 0) {
        return .default;
    }
    if (std.ascii.eqlIgnoreCase(text, "tcp")) {
        return .tcp;
    }
    if (std.ascii.eqlIgnoreCase(text, "socket")) {
        return .socket;
    }
    return Error.InvalidProtocol;
}

/// Boolean values for --ssl and --ssl-verify-server-cert. A bare flag means true.
fn boolValue(value: ?[]const u8) Error!bool {
    const text = value orelse return true;
    const truthy = [_][]const u8{ "1", "on", "true", "yes" };
    const falsy = [_][]const u8{ "0", "off", "false", "no" };
    for (truthy) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    for (falsy) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return false;
    }
    return Error.InvalidBoolValue;
}

/// Sets one TLS path option. Like the mysql.cc --ssl-ca family, it also enables TLS.
fn setTlsPath(options: *Options, field: *[]const u8, value: ?[]const u8) Error!void {
    field.* = try requiredValue(value);
    options.tls.enabled = true;
}

fn apply(allocator: Allocator, options: *Options, id: Id, value: ?[]const u8) Error!void {
    switch (id) {
        .host => options.host = try requiredValue(value),
        .database => options.database = try requiredValue(value),
        .user => options.user = try requiredValue(value),
        .port => {
            options.port = try parsePort(try requiredValue(value));
            options.protocol = .tcp;
        },
        .socket => {
            options.socket = try requiredValue(value);
            options.protocol = .socket;
        },
        .protocol => options.protocol = try protocolValue(value),
        .ssl => options.tls.enabled = try boolValue(value),
        .skip_ssl => options.tls.enabled = false,
        .ssl_ca => try setTlsPath(options, &options.tls.ca, value),
        .ssl_capath => try setTlsPath(options, &options.tls.capath, value),
        .ssl_cert => try setTlsPath(options, &options.tls.cert, value),
        .ssl_key => try setTlsPath(options, &options.tls.key, value),
        .ssl_cipher => try setTlsPath(options, &options.tls.cipher, value),
        .ssl_crl => try setTlsPath(options, &options.tls.crl, value),
        .ssl_crlpath => try setTlsPath(options, &options.tls.crlpath, value),
        .tls_version => try setTlsPath(options, &options.tls.tls_version, value),
        .ssl_verify_server_cert => options.tls.verify_server_cert = try boolValue(value),
        .skip_ssl_verify_server_cert => options.tls.verify_server_cert = false,
        .password => {
            if (value != null) {
                return Error.PasswordOnCommandLine;
            }
            options.prompt_password = true;
            options.password = "";
        },
        .execute => {
            const sql = try requiredValue(value);
            if (options.execute) |*text| {
                try text.append(allocator, '\n');
                try text.appendSlice(allocator, sql);
            } else {
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(allocator, sql);
                options.execute = text;
            }
        },
        .force => options.force = true,
        .delimiter => options.delimiter = try delimiterValue(value),
        .batch => options.batch = true,
        .table => options.table = true,
        .vertical => options.vertical = true,
        .raw => options.raw = true,
        .silent => options.silent +|= 1,
        .skip_column_names => options.column_names = false,
        .column_names => options.column_names = true,
        .pager => options.pager = value orelse "",
        .tee => options.tee = try requiredValue(value),
        .show_warnings => options.show_warnings = true,
        .help => options.show_help = true,
        .version => options.show_version = true,
    }
}

pub fn renderError(out: *std.Io.Writer, err: Error) !void {
    const message = switch (err) {
        Error.MissingOptionValue => "Missing value for option.",
        Error.InvalidPort => "Invalid port. Expected a base-10 unsigned integer.",
        Error.InvalidDelimiter => "Invalid delimiter. It cannot be empty or contain a backslash.",
        Error.TooManyDatabases => "Too many database arguments.",
        Error.UnknownOption => "Unknown option. Run thysql --help for the supported options.",
        Error.UnexpectedOptionValue => "This option does not take a value.",
        Error.PasswordOnCommandLine => "Password values are not accepted on the command line; use -p or MYSQL_PWD.",
        Error.InvalidProtocol => "Invalid protocol. Expected tcp or socket.",
        Error.InvalidBoolValue => "Invalid value for a boolean option. Use 1, 0, on, or off.",
        Error.OutOfMemory => "Out of memory.",
    };
    try out.print("{s}\n", .{message});
}

fn renderSpec(out: *std.Io.Writer, spec: Spec) !void {
    var left_buffer: [64]u8 = undefined;
    var left: std.Io.Writer = .fixed(&left_buffer);
    if (spec.short) |flag| {
        try left.print("-{c}, ", .{flag});
    } else {
        try left.writeAll("    ");
    }
    try left.print("--{s}", .{spec.long});
    if (spec.arg == .required) {
        try left.print("={s}", .{spec.arg_name});
    } else if (spec.arg == .optional and spec.arg_name.len > 0) {
        try left.print("[={s}]", .{spec.arg_name});
    }
    try out.print("  {s: <26}{s}\n", .{ left.buffered(), spec.help });
}

pub fn renderUsage(out: *std.Io.Writer) !void {
    try out.print(
        \\Usage: thysql [OPTIONS] [database]
        \\       thysql complete [OPTIONS] -D[prefix]
    , .{});
    for (group_titles) |group| {
        try out.print("\n{s}\n", .{group.title});
        for (specs) |spec| {
            if (spec.group == group.group) {
                try renderSpec(out, spec);
            }
        }
    }
    try out.print("\nPasswords are not accepted on the command line. Use -p to prompt or MYSQL_PWD for non-interactive use.\n", .{});
}

fn testEnv() std.process.Environ.Map {
    return std.process.Environ.Map.init(std.testing.allocator);
}

test "connection options default from environment" {
    var env = testEnv();
    defer env.deinit();
    try env.put("MARIADB_HOST", "maria.example");
    try env.put("MYSQL_HOST", "mysql.example");
    try env.put("MYSQL_TCP_PORT", "4407");
    try env.put("MYSQL_PWD", "env-secret");
    try env.put("USER", "jeff");

    const args = [_][]const u8{"thysql"};
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("maria.example", options.host);
    try std.testing.expectEqualStrings("jeff", options.user);
    try std.testing.expectEqualStrings("env-secret", options.password);
    try std.testing.expectEqual(@as(u32, 4407), options.port);
    try std.testing.expect(!options.prompt_password);
}

test "connection options parse mysql-style connection flags" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "-h127.0.0.1", "-P", "3307", "-u", "root", "-D", "test" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("127.0.0.1", options.host);
    try std.testing.expectEqual(@as(u32, 3307), options.port);
    try std.testing.expectEqualStrings("root", options.user);
    try std.testing.expectEqualStrings("test", options.database);
}

test "positional database follows password prompt flag" {
    var env = testEnv();
    defer env.deinit();
    try env.put("MYSQL_PWD", "ignored-when-prompting");

    const args = [_][]const u8{ "thysql", "-p", "app_db" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.prompt_password);
    try std.testing.expectEqualStrings("", options.password);
    try std.testing.expectEqualStrings("app_db", options.database);
}

test "positional database overrides database option" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "--database=from_flag", "from_positional" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("from_positional", options.database);
}

test "long option with explicit empty value stays empty" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "--database=", "from_positional" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("from_positional", options.database);
}

test "command-line password values are rejected" {
    var env = testEnv();
    defer env.deinit();

    const short_args = [_][]const u8{ "thysql", "-psecret" };
    try std.testing.expectError(Error.PasswordOnCommandLine, parse(std.testing.allocator, &short_args, &env));

    const long_args = [_][]const u8{ "thysql", "--password=secret" };
    try std.testing.expectError(Error.PasswordOnCommandLine, parse(std.testing.allocator, &long_args, &env));
}

test "short flags cluster and -s counts repeats" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "-sNE", "-ss" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), options.silent);
    try std.testing.expect(!options.column_names);
    try std.testing.expect(options.vertical);
}

test "execute collects statements in order and accepts dash-prefixed values" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "-e", "-- note\nselect 1", "--execute=select 2" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-- note\nselect 1\nselect 2", options.executeText().?);
    try std.testing.expect(options.isBatch(true));
}

test "option values are required where the option needs them" {
    var env = testEnv();
    defer env.deinit();

    const missing = [_][]const u8{ "thysql", "-h" };
    try std.testing.expectError(Error.MissingOptionValue, parse(std.testing.allocator, &missing, &env));

    const unknown = [_][]const u8{ "thysql", "--no-such-option" };
    try std.testing.expectError(Error.UnknownOption, parse(std.testing.allocator, &unknown, &env));

    const bad_short = [_][]const u8{ "thysql", "-z" };
    try std.testing.expectError(Error.UnknownOption, parse(std.testing.allocator, &bad_short, &env));

    const no_value = [_][]const u8{ "thysql", "--batch=yes" };
    try std.testing.expectError(Error.UnexpectedOptionValue, parse(std.testing.allocator, &no_value, &env));
}

test "double dash ends option parsing" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "--", "-h" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-h", options.database);
}

test "help and version flags" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "-?", "-V" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.show_help);
    try std.testing.expect(options.show_version);
}

test "result format follows mysql.cc: vertical, tab in batch or with -s, else table" {
    var env = testEnv();
    defer env.deinit();

    const plain = [_][]const u8{"thysql"};
    var interactive = try parse(std.testing.allocator, &plain, &env);
    defer interactive.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResultFormat.table, interactive.resultFormat(true, false));
    try std.testing.expectEqual(ResultFormat.tab, interactive.resultFormat(false, false));
    try std.testing.expectEqual(ResultFormat.vertical, interactive.resultFormat(false, true));

    const with_e = [_][]const u8{ "thysql", "-e", "select 1" };
    var execute = try parse(std.testing.allocator, &with_e, &env);
    defer execute.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResultFormat.tab, execute.resultFormat(true, false));

    const with_t = [_][]const u8{ "thysql", "-t", "-B" };
    var forced_table = try parse(std.testing.allocator, &with_t, &env);
    defer forced_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResultFormat.table, forced_table.resultFormat(false, false));

    const with_e_vertical = [_][]const u8{ "thysql", "-E", "-s" };
    var vertical = try parse(std.testing.allocator, &with_e_vertical, &env);
    defer vertical.deinit(std.testing.allocator);
    try std.testing.expectEqual(ResultFormat.vertical, vertical.resultFormat(true, false));
}

test "column names hide only in tab output with -ss or -N" {
    var env = testEnv();
    defer env.deinit();

    const one_s = [_][]const u8{ "thysql", "-s" };
    var single = try parse(std.testing.allocator, &one_s, &env);
    defer single.deinit(std.testing.allocator);
    try std.testing.expect(single.showColumnNames(.tab));

    const two_s = [_][]const u8{ "thysql", "-ss" };
    var double = try parse(std.testing.allocator, &two_s, &env);
    defer double.deinit(std.testing.allocator);
    try std.testing.expect(!double.showColumnNames(.tab));
    try std.testing.expect(double.showColumnNames(.table));

    const skip = [_][]const u8{ "thysql", "--skip-column-names", "--column-names" };
    var toggled = try parse(std.testing.allocator, &skip, &env);
    defer toggled.deinit(std.testing.allocator);
    try std.testing.expect(toggled.showColumnNames(.table));

    const dash_n = [_][]const u8{ "thysql", "-N" };
    var skipped = try parse(std.testing.allocator, &dash_n, &env);
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expect(!skipped.showColumnNames(.table));
}

test "delimiter option takes a value that is not empty or backslashed" {
    var env = testEnv();
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "--delimiter=$$" };
    var options = try parse(std.testing.allocator, &args, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("$$", options.delimiter);

    const empty = [_][]const u8{ "thysql", "--delimiter=" };
    try std.testing.expectError(Error.InvalidDelimiter, parse(std.testing.allocator, &empty, &env));

    const backslash = [_][]const u8{ "thysql", "--delimiter=\\" };
    try std.testing.expectError(Error.InvalidDelimiter, parse(std.testing.allocator, &backslash, &env));
}

test "usage lists every option in its group" {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try renderUsage(&out);
    const text = out.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "Connection options:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Execution options:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Output options:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -e, --execute=sql") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -N, --skip-column-names") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "      --column-names") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -?, --help") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -V, --version") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  -S, --socket=path") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "      --ssl-ca=file") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "      --skip-ssl") != null);
}

test "-P selects tcp and -S selects the socket; the last flag wins" {
    var env = testEnv();
    defer env.deinit();

    const socket_first = [_][]const u8{ "thysql", "-S", "/tmp/mysql.sock" };
    var by_socket = try parse(std.testing.allocator, &socket_first, &env);
    defer by_socket.deinit(std.testing.allocator);
    try std.testing.expectEqual(Protocol.socket, by_socket.protocol);
    try std.testing.expectEqualStrings("/tmp/mysql.sock", by_socket.socket);

    const port_after = [_][]const u8{ "thysql", "--socket=/tmp/mysql.sock", "-P", "3307" };
    var by_port = try parse(std.testing.allocator, &port_after, &env);
    defer by_port.deinit(std.testing.allocator);
    try std.testing.expectEqual(Protocol.tcp, by_port.protocol);
    try std.testing.expectEqual(@as(u32, 3307), by_port.port);

    const explicit = [_][]const u8{ "thysql", "-P", "3307", "--protocol=SOCKET" };
    var by_protocol = try parse(std.testing.allocator, &explicit, &env);
    defer by_protocol.deinit(std.testing.allocator);
    try std.testing.expectEqual(Protocol.socket, by_protocol.protocol);

    const plain = [_][]const u8{"thysql"};
    var none = try parse(std.testing.allocator, &plain, &env);
    defer none.deinit(std.testing.allocator);
    try std.testing.expectEqual(Protocol.default, none.protocol);
}

test "--protocol accepts tcp and socket, treats empty as unset, and rejects the rest" {
    var env = testEnv();
    defer env.deinit();

    const tcp = [_][]const u8{ "thysql", "--protocol=tcp" };
    var options = try parse(std.testing.allocator, &tcp, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(Protocol.tcp, options.protocol);

    const empty = [_][]const u8{ "thysql", "--protocol=" };
    var unset = try parse(std.testing.allocator, &empty, &env);
    defer unset.deinit(std.testing.allocator);
    try std.testing.expectEqual(Protocol.default, unset.protocol);

    const pipe = [_][]const u8{ "thysql", "--protocol=pipe" };
    try std.testing.expectError(Error.InvalidProtocol, parse(std.testing.allocator, &pipe, &env));
}

test "TLS path options imply --ssl, and --skip-ssl turns TLS off again" {
    var env = testEnv();
    defer env.deinit();

    const ca_only = [_][]const u8{ "thysql", "--ssl-ca=/tmp/ca.pem" };
    var with_ca = try parse(std.testing.allocator, &ca_only, &env);
    defer with_ca.deinit(std.testing.allocator);
    try std.testing.expect(with_ca.tls.enabled);
    try std.testing.expectEqualStrings("/tmp/ca.pem", with_ca.tls.ca);
    try std.testing.expectEqual(@as(?bool, null), with_ca.tls.verify_server_cert);

    const skipped = [_][]const u8{ "thysql", "--ssl-ca=/tmp/ca.pem", "--skip-ssl" };
    var off = try parse(std.testing.allocator, &skipped, &env);
    defer off.deinit(std.testing.allocator);
    try std.testing.expect(!off.tls.enabled);

    const reenabled = [_][]const u8{ "thysql", "--skip-ssl", "--ssl-cert", "client.pem", "--ssl-key=client-key.pem" };
    var on = try parse(std.testing.allocator, &reenabled, &env);
    defer on.deinit(std.testing.allocator);
    try std.testing.expect(on.tls.enabled);
    try std.testing.expectEqualStrings("client.pem", on.tls.cert);
    try std.testing.expectEqualStrings("client-key.pem", on.tls.key);

    const ssl_zero = [_][]const u8{ "thysql", "--ssl-ca=/tmp/ca.pem", "--ssl=0" };
    var disabled = try parse(std.testing.allocator, &ssl_zero, &env);
    defer disabled.deinit(std.testing.allocator);
    try std.testing.expect(!disabled.tls.enabled);

    const missing = [_][]const u8{ "thysql", "--ssl-capath" };
    try std.testing.expectError(Error.MissingOptionValue, parse(std.testing.allocator, &missing, &env));
}

test "TLS is on by default, and --skip-ssl turns it off" {
    var env = testEnv();
    defer env.deinit();

    const plain = [_][]const u8{"thysql"};
    var default = try parse(std.testing.allocator, &plain, &env);
    defer default.deinit(std.testing.allocator);
    try std.testing.expect(default.tls.enabled);
    try std.testing.expectEqual(@as(?bool, null), default.tls.verify_server_cert);

    const skip = [_][]const u8{ "thysql", "--skip-ssl" };
    var skipped = try parse(std.testing.allocator, &skip, &env);
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expect(!skipped.tls.enabled);
}

test "TLS verify flag takes a boolean, with a skip form" {
    var env = testEnv();
    defer env.deinit();

    const bare = [_][]const u8{ "thysql", "--ssl", "--ssl-verify-server-cert" };
    var verified = try parse(std.testing.allocator, &bare, &env);
    defer verified.deinit(std.testing.allocator);
    try std.testing.expect(verified.tls.enabled);
    try std.testing.expectEqual(@as(?bool, true), verified.tls.verify_server_cert);

    const zero = [_][]const u8{ "thysql", "--ssl-verify-server-cert=0" };
    var unverified = try parse(std.testing.allocator, &zero, &env);
    defer unverified.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, false), unverified.tls.verify_server_cert);

    const skip = [_][]const u8{ "thysql", "--ssl-verify-server-cert", "--skip-ssl-verify-server-cert" };
    var skipped = try parse(std.testing.allocator, &skip, &env);
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?bool, false), skipped.tls.verify_server_cert);

    const bad = [_][]const u8{ "thysql", "--ssl-verify-server-cert=maybe" };
    try std.testing.expectError(Error.InvalidBoolValue, parse(std.testing.allocator, &bad, &env));
}

test "pager, tee, and show-warnings flags" {
    var env = testEnv();
    defer env.deinit();

    const bare = [_][]const u8{ "thysql", "--pager" };
    var bare_pager = try parse(std.testing.allocator, &bare, &env);
    defer bare_pager.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", bare_pager.pager.?);

    const given = [_][]const u8{ "thysql", "--pager=less -S", "--tee=/tmp/out.txt", "--show-warnings" };
    var options = try parse(std.testing.allocator, &given, &env);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("less -S", options.pager.?);
    try std.testing.expectEqualStrings("/tmp/out.txt", options.tee.?);
    try std.testing.expect(options.show_warnings);

    const plain = [_][]const u8{"thysql"};
    var none = try parse(std.testing.allocator, &plain, &env);
    defer none.deinit(std.testing.allocator);
    try std.testing.expect(none.pager == null);
    try std.testing.expect(none.tee == null);
    try std.testing.expect(!none.show_warnings);

    const missing = [_][]const u8{ "thysql", "--tee" };
    try std.testing.expectError(Error.MissingOptionValue, parse(std.testing.allocator, &missing, &env));
}

test "usage describes the optional pager command and the tee file" {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try renderUsage(&out);
    const text = out.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "      --pager[=command]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "      --tee=file") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "      --show-warnings") != null);
}
