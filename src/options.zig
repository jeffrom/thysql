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
    OutOfMemory,
};

pub const ResultFormat = enum { table, tab, vertical };

pub const Id = enum {
    host,
    database,
    port,
    user,
    password,
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
    .{ .id = .port, .long = "port", .short = 'P', .arg = .required, .arg_name = "#", .group = .connection, .help = "Port number. Defaults to $MYSQL_TCP_PORT, then 3306." },
    .{ .id = .user, .long = "user", .short = 'u', .arg = .required, .arg_name = "name", .group = .connection, .help = "User for login. Defaults to $USER when set." },
    .{ .id = .password, .long = "password", .short = 'p', .arg = .optional, .group = .connection, .help = "Prompt for password without echoing input." },
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
    .{ .id = .help, .long = "help", .short = '?', .group = .other, .help = "Display this help and exit." },
    .{ .id = .version, .long = "version", .short = 'V', .group = .other, .help = "Output version information and exit." },
};

const group_titles = [_]struct { group: Group, title: []const u8 }{
    .{ .group = .connection, .title = "Connection options:" },
    .{ .group = .execution, .title = "Execution options:" },
    .{ .group = .output, .title = "Output options:" },
    .{ .group = .other, .title = "Help and version:" },
};

pub const Options = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    password: []const u8 = "",
    database: []const u8 = "",
    port: u32 = 3306,
    prompt_password: bool = false,
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

fn apply(allocator: Allocator, options: *Options, id: Id, value: ?[]const u8) Error!void {
    switch (id) {
        .host => options.host = try requiredValue(value),
        .database => options.database = try requiredValue(value),
        .user => options.user = try requiredValue(value),
        .port => options.port = try parsePort(try requiredValue(value)),
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
}
