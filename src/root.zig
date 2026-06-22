//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Mysql = @import("mysql.zig");
const Batch = @import("batch.zig");
const Readline = @import("readline.zig");
pub const Unicode = @import("unicode.zig");

const CliError = error{
    MissingOptionValue,
    InvalidPort,
    TooManyDatabases,
    UnknownOption,
    PasswordOnCommandLine,
};

const CliOptions = struct {
    host: []const u8,
    user: []const u8,
    password: []const u8,
    database: []const u8,
    port: u32,
    prompt_password: bool = false,
};

fn connectionPrompt(allocator: Allocator, user: []const u8, host: []const u8, port: u32, database: []const u8) ![:0]u8 {
    const db_name = if (database.len == 0) "(none)" else database;
    if (user.len == 0) {
        return try std.fmt.allocPrintSentinel(allocator, "{s}:{}/{s}", .{ host, port, db_name }, 0);
    }
    return try std.fmt.allocPrintSentinel(allocator, "{s}@{s}:{}/{s}", .{ user, host, port, db_name }, 0);
}

fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    return env.get(name);
}

fn defaultHost(env: *const std.process.Environ.Map) []const u8 {
    return envValue(env, "MARIADB_HOST") orelse
        envValue(env, "MYSQL_HOST") orelse
        "localhost";
}

fn defaultUser(env: *const std.process.Environ.Map) []const u8 {
    return envValue(env, "USER") orelse "";
}

fn defaultPort(env: *const std.process.Environ.Map) CliError!u32 {
    const value = envValue(env, "MYSQL_TCP_PORT") orelse return 3306;
    return std.fmt.parseUnsigned(u32, value, 10) catch CliError.InvalidPort;
}

fn parsePort(value: []const u8) CliError!u32 {
    return std.fmt.parseUnsigned(u32, value, 10) catch CliError.InvalidPort;
}

fn longOptionValue(args: []const []const u8, index: *usize, eq_index: ?usize, body: []const u8) CliError![]const u8 {
    if (eq_index) |idx| {
        return body[idx + 1 ..];
    }

    index.* += 1;
    if (index.* >= args.len) {
        return CliError.MissingOptionValue;
    }
    return args[index.*];
}

fn shortOptionValue(args: []const []const u8, index: *usize, inline_value: []const u8) CliError![]const u8 {
    if (inline_value.len != 0) {
        return inline_value;
    }

    index.* += 1;
    if (index.* >= args.len) {
        return CliError.MissingOptionValue;
    }
    return args[index.*];
}

fn setPositionalDatabase(options: *CliOptions, seen_positional_database: *bool, database: []const u8) CliError!void {
    if (seen_positional_database.*) {
        return CliError.TooManyDatabases;
    }
    seen_positional_database.* = true;
    options.database = database;
}

fn parseConnectionOptions(args: []const []const u8, env: *const std.process.Environ.Map) CliError!CliOptions {
    var options = CliOptions{
        .host = defaultHost(env),
        .user = defaultUser(env),
        .password = envValue(env, "MYSQL_PWD") orelse "",
        .database = "",
        .port = try defaultPort(env),
    };

    var i: usize = 1;
    var seen_positional_database = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len == 0) {
            try setPositionalDatabase(&options, &seen_positional_database, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try setPositionalDatabase(&options, &seen_positional_database, args[i]);
            }
            break;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq_index = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq_index) |idx| body[0..idx] else body;

            if (std.mem.eql(u8, name, "host")) {
                options.host = try longOptionValue(args, &i, eq_index, body);
            } else if (std.mem.eql(u8, name, "database")) {
                options.database = try longOptionValue(args, &i, eq_index, body);
            } else if (std.mem.eql(u8, name, "port")) {
                options.port = try parsePort(try longOptionValue(args, &i, eq_index, body));
            } else if (std.mem.eql(u8, name, "user")) {
                options.user = try longOptionValue(args, &i, eq_index, body);
            } else if (std.mem.eql(u8, name, "password")) {
                if (eq_index != null) {
                    return CliError.PasswordOnCommandLine;
                }
                options.prompt_password = true;
                options.password = "";
            } else {
                return CliError.UnknownOption;
            }
            continue;
        }

        if (arg[0] == '-' and arg.len > 1) {
            switch (arg[1]) {
                'h' => options.host = try shortOptionValue(args, &i, arg[2..]),
                'D' => options.database = try shortOptionValue(args, &i, arg[2..]),
                'P' => options.port = try parsePort(try shortOptionValue(args, &i, arg[2..])),
                'u' => options.user = try shortOptionValue(args, &i, arg[2..]),
                'p' => {
                    if (arg.len > 2) {
                        return CliError.PasswordOnCommandLine;
                    }
                    options.prompt_password = true;
                    options.password = "";
                },
                else => return CliError.UnknownOption,
            }
            continue;
        }

        try setPositionalDatabase(&options, &seen_positional_database, arg);
    }

    return options;
}

fn renderUsage(out: *std.Io.Writer) !void {
    try out.print(
        \\Usage: thysql [OPTIONS] [database]
        \\
        \\Connection options:
        \\  -h, --host=name       Connect to host. Defaults to $MARIADB_HOST, $MYSQL_HOST, then localhost.
        \\  -D, --database=name   Database to use.
        \\  -P, --port=#         Port number. Defaults to $MYSQL_TCP_PORT, then 3306.
        \\  -u, --user=name       User for login. Defaults to $USER when set.
        \\  -p, --password        Prompt for password without echoing input.
        \\
        \\Passwords are not accepted on the command line. Use -p to prompt or MYSQL_PWD for non-interactive use.
        \\
    , .{});
}

fn renderCliError(out: *std.Io.Writer, err: CliError) !void {
    switch (err) {
        CliError.MissingOptionValue => try out.print("Missing value for connection option.\n", .{}),
        CliError.InvalidPort => try out.print("Invalid port. Expected a base-10 unsigned integer.\n", .{}),
        CliError.TooManyDatabases => try out.print("Too many database arguments.\n", .{}),
        CliError.UnknownOption => try out.print("Unknown connection option.\n", .{}),
        CliError.PasswordOnCommandLine => try out.print("Password values are not accepted on the command line; use -p or MYSQL_PWD.\n", .{}),
    }
}

fn readHiddenLine(allocator: Allocator, io: std.Io, stderr: *std.Io.Writer, prompt: []const u8) ![]u8 {
    try stderr.print("{s}", .{prompt});
    try stderr.flush();

    const stdin_fd = std.posix.STDIN_FILENO;
    const original_term = try std.posix.tcgetattr(stdin_fd);
    var hidden_term = original_term;
    hidden_term.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin_fd, .NOW, hidden_term);
    defer std.posix.tcsetattr(stdin_fd, .NOW, original_term) catch {};
    defer stderr.print("\n", .{}) catch {};

    var stdin_buffer: [128]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read = try stdin_reader.interface.readSliceShort(&byte);
        if (read == 0 or byte[0] == '\n') {
            break;
        }
        if (byte[0] == '\r') {
            break;
        }
        try line.append(allocator, byte[0]);
    }

    return line.toOwnedSlice(allocator);
}

fn useDatabaseName(line: []const u8) ?[]const u8 {
    var remaining = std.mem.trim(u8, line, " \t\r\n");
    if (remaining.len == 0) {
        return null;
    }

    if (remaining[remaining.len - 1] == ';') {
        remaining = std.mem.trim(u8, remaining[0 .. remaining.len - 1], " \t\r\n");
    }

    if (remaining.len < 3 or !std.ascii.eqlIgnoreCase(remaining[0..3], "use")) {
        return null;
    }

    if (remaining.len > 3 and !std.ascii.isWhitespace(remaining[3])) {
        return null;
    }

    var name = std.mem.trim(u8, remaining[3..], " \t\r\n");
    if (name.len >= 2 and name[0] == '`' and name[name.len - 1] == '`') {
        name = name[1 .. name.len - 1];
    }
    return if (name.len == 0) null else name;
}

fn executeQuery(db: *Mysql.DB, io: std.Io, stdout: *std.Io.Writer, query: Batch.Query, interactive: bool) !bool {
    if (query.sql.len == 0) {
        return true;
    }

    if (useDatabaseName(query.sql)) |database| {
        const database_z = try db.allocator.dupeZ(u8, database);
        defer db.allocator.free(database_z);

        db.selectDatabase(database_z) catch |err| {
            switch (err) {
                Mysql.DBError.ExecError => {
                    try db.renderLastError(stdout);
                    return false;
                },
                else => return err,
            }
        };

        if (interactive) {
            try Readline.rebuildCompletions();
            try stdout.print("Database changed\n", .{});
            try stdout.flush();
        }
        return true;
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var exec_result = db.exec(query.sql) catch |err| {
        switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                try db.renderLastError(stdout);
                return false;
            },
            else => return err,
        }
    };

    while (true) {
        const elapsed_ns = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        switch (exec_result) {
            .result => |result| {
                defer Mysql.freeResult(result);
                const warnings = db.warningCount();
                if (query.vertical) {
                    try Mysql.render_result_vertical_timed_with_warnings(stdout, result, elapsed_ns, warnings);
                } else {
                    try Mysql.render_result_timed_with_warnings(stdout, result, elapsed_ns, warnings);
                }
            },
            .ok => |ok| try Mysql.render_ok_timed(stdout, ok, elapsed_ns),
        }

        exec_result = (db.nextResult() catch |err| {
            switch (err) {
                Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                    try db.renderLastError(stdout);
                    return false;
                },
                else => return err,
            }
        }) orelse break;
    }

    // const affected = C.mysql_affected_rows(self.conn);
    // std.debug.print("{d} row(s) affected\n", .{affected});

    return true;
}

fn readOneLine(db: *Mysql.DB, io: std.Io, stdout: *std.Io.Writer) !bool {
    const prompt = try connectionPrompt(db.allocator, db.user, db.host, db.port, db.database);
    defer db.allocator.free(prompt);

    const maybeLine = Readline.one(prompt);
    if (maybeLine == null) {
        return true;
    }
    defer Readline.freeLine(@ptrCast(@constCast(maybeLine)));

    const line = maybeLine.?;
    if (line.len == 0) {
        return false;
    }

    _ = try executeQuery(db, io, stdout, Batch.parseQueryInput(line), true);
    return false;
}

fn executeBatchQuery(db: *Mysql.DB, io: std.Io, stdout: *std.Io.Writer, query: Batch.Query) !Batch.QueryResult {
    if (query.sql.len == 0) {
        return .{};
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);

    if (useDatabaseName(query.sql)) |database| {
        const database_z = try db.allocator.dupeZ(u8, database);
        defer db.allocator.free(database_z);

        db.selectDatabase(database_z) catch |err| {
            switch (err) {
                Mysql.DBError.ExecError => {
                    try db.renderLastError(stdout);
                    return .{ .success = false };
                },
                else => return err,
            }
        };

        return .{
            .elapsed_ns = @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds),
        };
    }

    var rows_affected: u64 = 0;
    var exec_result = db.exec(query.sql) catch |err| {
        switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                try db.renderLastError(stdout);
                return .{ .success = false };
            },
            else => return err,
        }
    };

    while (true) {
        switch (exec_result) {
            .result => |result| {
                defer Mysql.freeResult(result);
                if (query.vertical) {
                    try Mysql.render_result_vertical(stdout, result);
                } else {
                    try Mysql.render_result(stdout, result);
                }
            },
            .ok => |ok| {
                if (Mysql.affectedRows(ok)) |affected| {
                    rows_affected += affected;
                }
            },
        }

        exec_result = (db.nextResult() catch |err| {
            switch (err) {
                Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                    try db.renderLastError(stdout);
                    return .{ .success = false };
                },
                else => return err,
            }
        }) orelse break;
    }

    return .{
        .rows_affected = rows_affected,
        .elapsed_ns = @intCast(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds),
    };
}

pub fn runREPL(
    allocator: Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    process_args: std.process.Args,
    env: *const std.process.Environ.Map,
) !u8 {
    var args_iter = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer args_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (args_iter.next()) |arg| {
        try args.append(allocator, arg);
    }

    var options = parseConnectionOptions(args.items, env) catch |err| {
        try renderCliError(stderr, err);
        try renderUsage(stderr);
        return 1;
    };

    const stdin = std.Io.File.stdin();
    const stdin_is_tty = try stdin.isTty(io);

    var prompted_password: ?[]u8 = null;
    defer if (prompted_password) |password| allocator.free(password);
    if (options.prompt_password) {
        if (!stdin_is_tty) {
            try stderr.print("Cannot prompt for a password while reading SQL from stdin; use MYSQL_PWD.\n", .{});
            return 1;
        }
        prompted_password = try readHiddenLine(allocator, io, stderr, "Enter password: ");
        options.password = prompted_password.?;
    }

    var db = try Mysql.DB.init(allocator, .{
        .host = options.host,
        .user = options.user,
        .password = options.password,
        .database = options.database,
        .port = options.port,
    });
    defer db.close();

    if (!stdin_is_tty) {
        return try Batch.run(db.allocator, io, stdin, stdout, stderr, &db, executeBatchQuery);
    }

    try Readline.setup();

    while (true) {
        const done = try readOneLine(&db, io, stdout);
        if (done) {
            break;
        }
    }

    return 0;
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "detect USE database command" {
    try std.testing.expectEqualStrings("test", useDatabaseName("use test").?);
    try std.testing.expectEqualStrings("test", useDatabaseName("USE test;").?);
    try std.testing.expectEqualStrings("test", useDatabaseName("  use   test  ;  ").?);
    try std.testing.expectEqualStrings("my-db", useDatabaseName("use `my-db`;").?);
    try std.testing.expect(useDatabaseName("user test") == null);
    try std.testing.expect(useDatabaseName("select 1") == null);
}

test "connection prompt shows connection and database" {
    const with_database = try connectionPrompt(std.testing.allocator, "root", "db.example", 3307, "app");
    defer std.testing.allocator.free(with_database);
    try std.testing.expectEqualStrings("root@db.example:3307/app", with_database);

    const without_database = try connectionPrompt(std.testing.allocator, "", "localhost", 3306, "");
    defer std.testing.allocator.free(without_database);
    try std.testing.expectEqualStrings("localhost:3306/(none)", without_database);
}

test "connection options default from environment" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MARIADB_HOST", "maria.example");
    try env.put("MYSQL_HOST", "mysql.example");
    try env.put("MYSQL_TCP_PORT", "4407");
    try env.put("MYSQL_PWD", "env-secret");
    try env.put("USER", "jeff");

    const args = [_][]const u8{"thysql"};
    const options = try parseConnectionOptions(&args, &env);
    try std.testing.expectEqualStrings("maria.example", options.host);
    try std.testing.expectEqualStrings("jeff", options.user);
    try std.testing.expectEqualStrings("env-secret", options.password);
    try std.testing.expectEqual(@as(u32, 4407), options.port);
    try std.testing.expect(!options.prompt_password);
}

test "connection options parse mysql-style connection flags" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "-h127.0.0.1", "-P", "3307", "-u", "root", "-D", "test" };
    const options = try parseConnectionOptions(&args, &env);
    try std.testing.expectEqualStrings("127.0.0.1", options.host);
    try std.testing.expectEqual(@as(u32, 3307), options.port);
    try std.testing.expectEqualStrings("root", options.user);
    try std.testing.expectEqualStrings("test", options.database);
}

test "positional database follows password prompt flag" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MYSQL_PWD", "ignored-when-prompting");

    const args = [_][]const u8{ "thysql", "-p", "app_db" };
    const options = try parseConnectionOptions(&args, &env);
    try std.testing.expect(options.prompt_password);
    try std.testing.expectEqualStrings("", options.password);
    try std.testing.expectEqualStrings("app_db", options.database);
}

test "positional database overrides database option" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "--database=from_flag", "from_positional" };
    const options = try parseConnectionOptions(&args, &env);
    try std.testing.expectEqualStrings("from_positional", options.database);
}

test "long option with explicit empty value stays empty" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const args = [_][]const u8{ "thysql", "--database=", "from_positional" };
    const options = try parseConnectionOptions(&args, &env);
    try std.testing.expectEqualStrings("from_positional", options.database);
}

test "command-line password values are rejected" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const short_args = [_][]const u8{ "thysql", "-psecret" };
    try std.testing.expectError(CliError.PasswordOnCommandLine, parseConnectionOptions(&short_args, &env));

    const long_args = [_][]const u8{ "thysql", "--password=secret" };
    try std.testing.expectError(CliError.PasswordOnCommandLine, parseConnectionOptions(&long_args, &env));
}

test {
    _ = .{
        @import("batch.zig"),
        @import("mysql.zig"),
        @import("unicode.zig"),
    };
}
