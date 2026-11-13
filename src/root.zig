//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Mysql = @import("mysql.zig");
const Batch = @import("batch.zig");
const Completion = @import("completion.zig");
const Options = @import("options.zig");
const Readline = @import("readline.zig");
pub const Unicode = @import("unicode.zig");

var sigint_requested = std.atomic.Value(bool).init(false);
var query_executing = std.atomic.Value(bool).init(false);

fn connectionPrompt(allocator: Allocator, user: []const u8, host: []const u8, port: u32, database: []const u8) ![:0]u8 {
    const db_name = if (database.len == 0) "(none)" else database;
    if (user.len == 0) {
        return try std.fmt.allocPrintSentinel(allocator, "{s}:{}/{s}> ", .{ host, port, db_name }, 0);
    }
    return try std.fmt.allocPrintSentinel(allocator, "{s}@{s}:{}/{s}> ", .{ user, host, port, db_name }, 0);
}

fn envValue(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    return env.get(name);
}

fn renderVersion(out: *std.Io.Writer) !void {
    try out.print("thysql, client library {s}\n", .{Mysql.clientInfo()});
    try out.flush();
}

fn handleSigint(_: std.posix.SIG) callconv(.c) void {
    if (query_executing.load(.monotonic)) {
        sigint_requested.store(true, .release);
    }
}

const QueryInterruptWorker = struct {
    db: *Mysql.DB,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    old_sigint: std.posix.Sigaction = undefined,

    fn start(self: *QueryInterruptWorker) !void {
        self.running.store(true, .release);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigint },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, &self.old_sigint);
        errdefer {
            self.running.store(false, .release);
            std.posix.sigaction(.INT, &self.old_sigint, null);
        }
        self.thread = try std.Thread.spawn(.{}, QueryInterruptWorker.run, .{self});
    }

    fn stop(self: *QueryInterruptWorker) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        std.posix.sigaction(.INT, &self.old_sigint, null);
    }

    fn run(self: *QueryInterruptWorker) void {
        while (self.running.load(.acquire)) {
            if (sigint_requested.swap(false, .acq_rel) and query_executing.load(.acquire)) {
                self.db.killRunningQuery() catch {};
            }
            pollSleep();
        }
    }

    fn pollSleep() void {
        const request: std.c.timespec = .{
            .sec = 0,
            .nsec = 10_000_000,
        };
        _ = std.c.nanosleep(&request, null);
    }
};

fn beginInterruptibleQuery() void {
    sigint_requested.store(false, .release);
    query_executing.store(true, .release);
}

fn endInterruptibleQuery() void {
    query_executing.store(false, .release);
    sigint_requested.store(false, .release);
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
        const database_z = try db.allocator.dupeSentinel(u8, database, 0);
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
    beginInterruptibleQuery();
    defer endInterruptibleQuery();

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

fn interactivePrompt(allocator: Allocator, db: *Mysql.DB, scanner: *const Batch.Scanner) ![:0]u8 {
    return switch (scanner.promptKind()) {
        .main => connectionPrompt(allocator, db.user, db.host, db.port, db.database),
        .continuation => try allocator.dupeSentinel(u8, "    -> ", 0),
        .single_quote => try allocator.dupeSentinel(u8, "    '> ", 0),
        .double_quote => try allocator.dupeSentinel(u8, "    \"> ", 0),
        .backtick => try allocator.dupeSentinel(u8, "    `> ", 0),
        .block_comment => try allocator.dupeSentinel(u8, "   /*> ", 0),
    };
}

fn renderConnectionBanner(
    stdout: *std.Io.Writer,
    server_name: []const u8,
    connection_id: u64,
    server_version: []const u8,
    client_info: []const u8,
) !void {
    const display_server_name = if (server_name.len == 0) "MySQL" else server_name;
    try stdout.print(
        \\Welcome to thysql.  Commands end with ; or \g.
        \\Your {s} connection id is {}
        \\Server version: {s}
        \\Client library version: {s}
        \\
        \\
    , .{ display_server_name, connection_id, server_version, client_info });
    try stdout.flush();
}

fn appendHistoryChar(entry: *std.ArrayList(u8), allocator: Allocator, byte: u8, in_string: *u8, escaped: *bool) !void {
    switch (byte) {
        '\n' => try entry.append(allocator, if (in_string.* == 0) ' ' else '\n'),
        '\\' => {
            try entry.append(allocator, byte);
            if (in_string.* != 0) {
                escaped.* = !escaped.*;
            }
        },
        '\'', '"', '`' => {
            if (escaped.*) {
                escaped.* = false;
            } else if (in_string.* == 0) {
                in_string.* = byte;
            } else if (in_string.* == byte) {
                in_string.* = 0;
            }
            try entry.append(allocator, byte);
        },
        else => {
            escaped.* = false;
            try entry.append(allocator, byte);
        },
    }
}

/// Formats a statement for the history. It ends with the delimiter in effect, so recalling it still runs.
fn formatHistoryEntry(allocator: Allocator, query: Batch.Query, delimiter: []const u8) ![:0]u8 {
    var entry: std.ArrayList(u8) = .empty;
    errdefer entry.deinit(allocator);

    var in_string: u8 = 0;
    var escaped = false;
    for (query.sql) |byte| {
        try appendHistoryChar(&entry, allocator, byte, &in_string, &escaped);
    }
    if (query.vertical) {
        try entry.appendSlice(allocator, "\\G");
    } else {
        try entry.appendSlice(allocator, delimiter);
    }

    return try entry.toOwnedSliceSentinel(allocator, 0);
}

fn addQueryToHistory(allocator: Allocator, query: Batch.Query, delimiter: []const u8) !void {
    if (query.sql.len == 0) {
        return;
    }

    const entry = try formatHistoryEntry(allocator, query, delimiter);
    defer allocator.free(entry);
    Readline.addHistory(entry);
}

fn rememberLastQuery(allocator: Allocator, last_query: *std.ArrayList(u8), query: Batch.Query) !void {
    if (query.sql.len == 0) {
        return;
    }

    last_query.clearRetainingCapacity();
    try last_query.appendSlice(allocator, query.sql);
    if (query.vertical) {
        try last_query.appendSlice(allocator, "\\G");
    }
}

fn editorInitialQuery(scanner: *const Batch.Scanner, last_query: *const std.ArrayList(u8)) []const u8 {
    return if (scanner.buffer.items.len == 0 and last_query.items.len != 0)
        last_query.items
    else
        scanner.buffer.items;
}

fn isEditCommand(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, "\\e") or
        std.ascii.eqlIgnoreCase(trimmed, "edit") or
        std.ascii.eqlIgnoreCase(trimmed, "edit;");
}

fn isClearCommand(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.mem.eql(u8, trimmed, "\\c") or
        std.ascii.eqlIgnoreCase(trimmed, "clear") or
        std.ascii.eqlIgnoreCase(trimmed, "clear;");
}

fn tempSqlPath(allocator: Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]u8 {
    const tmp_dir = envValue(env, "TMPDIR") orelse "/tmp";
    const timestamp = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const filename = try std.fmt.allocPrint(allocator, "thysql-{}-{}.sql", .{ std.c.getpid(), timestamp });
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &.{ tmp_dir, filename });
}

fn appendEditorArgv(allocator: Allocator, argv: *std.ArrayList([]const u8), editor: []const u8, path: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, editor, " \t\r\n");
    while (parts.next()) |part| {
        try argv.append(allocator, part);
    }
    try argv.append(allocator, path);
}

fn editorCommand(env: *const std.process.Environ.Map) []const u8 {
    if (envValue(env, "EDITOR")) |editor| {
        if (std.mem.trim(u8, editor, " \t\r\n").len != 0) {
            return editor;
        }
    }
    if (envValue(env, "VISUAL")) |visual| {
        if (std.mem.trim(u8, visual, " \t\r\n").len != 0) {
            return visual;
        }
    }
    return "vi";
}

fn trimRightBytes(input: []const u8, values: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values, input[end - 1]) != null) {
        end -= 1;
    }
    return input[0..end];
}

fn openEditorForQuery(
    allocator: Allocator,
    io: std.Io,
    stderr: *std.Io.Writer,
    env: *const std.process.Environ.Map,
    query: []const u8,
) !?[]u8 {
    const editor = editorCommand(env);
    const path = try tempSqlPath(allocator, io, env);
    defer allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = path,
        .data = query,
        .flags = .{ .exclusive = true },
    });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try appendEditorArgv(allocator, &argv, editor, path);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try stderr.print("Editor command failed: {s}: {}\n", .{ editor, err });
        return null;
    };

    const term = child.wait(io) catch |err| {
        try stderr.print("Editor command failed: {s}: {}\n", .{ editor, err });
        return null;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            try stderr.print("Editor command exited with status {}: {s}\n", .{ code, editor });
            return null;
        },
        .signal => |signal| {
            try stderr.print("Editor command terminated by signal {}: {s}\n", .{ signal, editor });
            return null;
        },
        .stopped => |signal| {
            try stderr.print("Editor command stopped by signal {}: {s}\n", .{ signal, editor });
            return null;
        },
        .unknown => |status| {
            try stderr.print("Editor command failed with status {}: {s}\n", .{ status, editor });
            return null;
        },
    }

    return try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(16 * 1024 * 1024));
}

/// What the REPL needs to run a statement typed at the prompt.
const ReplContext = struct {
    db: *Mysql.DB,
    io: std.Io,
    scanner: *Batch.Scanner,
    last_query: *std.ArrayList(u8),
    /// Batch state for statements typed at the prompt. It carries the force flag and `source` depth.
    session: Batch.Session,
};

/// Runs one statement typed at the prompt. Errors are printed, and the REPL keeps going.
/// Statements from a sourced file are run, but they are not added to history.
fn executeReplQuery(context: *ReplContext, stdout: *std.Io.Writer, stderr: *std.Io.Writer, query: Batch.Query) !bool {
    _ = stderr;
    const allocator = context.db.allocator;
    if (context.session.depth == 0) {
        try rememberLastQuery(allocator, context.last_query, query);
        try addQueryToHistory(allocator, query, context.scanner.delimiterText());
    }
    return try executeQuery(context.db, context.io, stdout, query, true);
}

fn feedInteractiveInput(
    context: *ReplContext,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    input: []const u8,
    append_newline_if_pending: bool,
) !void {
    const scanner = context.scanner;
    const session = &context.session;
    var completed_statement = false;
    for (input) |byte| {
        if (try scanner.feed(context.db.allocator, byte)) {
            completed_statement = true;
            _ = try Batch.runStatement(session, scanner, 0, stdout, stderr, context, executeReplQuery);
        }
    }

    if (append_newline_if_pending and (!completed_statement or scanner.pendingQuery().sql.len != 0)) {
        // The newline ends a client command line such as `delimiter $$`.
        if (try scanner.feed(context.db.allocator, '\n')) {
            _ = try Batch.runStatement(session, scanner, 0, stdout, stderr, context, executeReplQuery);
        }
    }
    if (scanner.pendingQuery().sql.len == 0) {
        scanner.reset();
    }
}

fn readOneLine(
    context: *ReplContext,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    env: *const std.process.Environ.Map,
) !bool {
    const db = context.db;
    const io = context.io;
    const scanner = context.scanner;
    const last_query = context.last_query;
    const prompt = try interactivePrompt(db.allocator, db, scanner);
    defer db.allocator.free(prompt);

    const maybeLine = Readline.one(prompt);
    if (maybeLine == null) {
        return true;
    }

    const line = maybeLine.?;
    defer Readline.freeLine(@ptrCast(@constCast(line.ptr)));
    if (line.len > 1) {
        Readline.removeLastHistory();
    }
    if (isClearCommand(line)) {
        scanner.reset();
        return false;
    }
    if (isEditCommand(line)) {
        const edited = try openEditorForQuery(db.allocator, io, stderr, env, editorInitialQuery(scanner, last_query));
        if (edited) |contents| {
            defer db.allocator.free(contents);
            try scanner.replacePending(db.allocator, trimRightBytes(contents, "\r\n"));
        }
        return false;
    }
    if (line.len == 0 and scanner.pendingQuery().sql.len == 0) {
        return false;
    }

    try feedInteractiveInput(context, stdout, stderr, line, true);
    return false;
}

const BatchContext = struct {
    db: *Mysql.DB,
    options: *const Options.Options,
    stdin_is_tty: bool,
};

/// Runs one batch statement. Results go to stdout, and errors go to stderr
/// with the statement's line number. Returns false on error.
fn executeBatchQuery(context: BatchContext, stdout: *std.Io.Writer, stderr: *std.Io.Writer, query: Batch.Query) !bool {
    const db = context.db;
    if (query.sql.len == 0) {
        return true;
    }

    if (useDatabaseName(query.sql)) |database| {
        const database_z = try db.allocator.dupeSentinel(u8, database, 0);
        defer db.allocator.free(database_z);

        db.selectDatabase(database_z) catch |err| {
            switch (err) {
                Mysql.DBError.ExecError => {
                    try db.renderLastErrorAt(stderr, query.line);
                    return false;
                },
                else => return err,
            }
        };
        return true;
    }

    var exec_result = db.exec(query.sql) catch |err| {
        switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                try db.renderLastErrorAt(stderr, query.line);
                return false;
            },
            else => return err,
        }
    };

    const format = context.options.resultFormat(context.stdin_is_tty, query.vertical);
    const column_names = context.options.showColumnNames(format);
    while (true) {
        switch (exec_result) {
            .result => |result| {
                defer Mysql.freeResult(result);
                try Mysql.render_script_result(stdout, result, format, column_names, context.options.raw);
            },
            .ok => {},
        }

        exec_result = (db.nextResult() catch |err| {
            switch (err) {
                Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                    try db.renderLastErrorAt(stderr, query.line);
                    return false;
                },
                else => return err,
            }
        }) orelse break;
    }

    return true;
}

fn runBatch(
    io: std.Io,
    stdin: std.Io.File,
    stdin_is_tty: bool,
    stderr_is_tty: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    db: *Mysql.DB,
    options: *const Options.Options,
) !u8 {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    var execute_reader: std.Io.Reader = undefined;
    var input: *std.Io.Reader = &stdin_reader.interface;
    var run_options = Batch.RunOptions{ .force = options.force, .delimiter = options.delimiter, .io = io };

    if (options.executeText()) |text| {
        execute_reader = std.Io.Reader.fixed(text);
        input = &execute_reader;
    } else {
        run_options.progress_total = Batch.stdinProgressTotal(stdin, io);
        run_options.show_progress = stderr_is_tty;
    }

    const context = BatchContext{
        .db = db,
        .options = options,
        .stdin_is_tty = stdin_is_tty,
    };
    return try Batch.run(db.allocator, input, stdout, stderr, run_options, context, executeBatchQuery);
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

    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "complete")) {
        return try Completion.run(allocator, stdout, stderr, args.items, env);
    }

    var options = Options.parse(allocator, args.items, env) catch |err| {
        try Options.renderError(stderr, err);
        try Options.renderUsage(stderr);
        return 1;
    };
    defer options.deinit(allocator);

    if (options.show_help) {
        try Options.renderUsage(stdout);
        try stdout.flush();
        return 0;
    }
    if (options.show_version) {
        try renderVersion(stdout);
        return 0;
    }

    const stdin = std.Io.File.stdin();
    const stdin_is_tty = try stdin.isTty(io);
    const stderr_is_tty = try std.Io.File.stderr().isTty(io);

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
        .socket = options.socket,
        .protocol = options.protocol,
        .tls = options.tls,
    });
    defer db.close();

    if (options.isBatch(stdin_is_tty)) {
        return try runBatch(io, stdin, stdin_is_tty, stderr_is_tty, stdout, stderr, &db, &options);
    }

    try Readline.setup(allocator, io, env);
    try renderConnectionBanner(stdout, db.serverName(), db.connectionId(), db.serverVersion(), Mysql.clientInfo());

    var interrupt_worker = QueryInterruptWorker{ .db = &db };
    try interrupt_worker.start();
    defer interrupt_worker.stop();

    var interactive_scanner: Batch.Scanner = .{};
    defer interactive_scanner.deinit(allocator);
    try interactive_scanner.setDelimiter(options.delimiter);
    var last_query: std.ArrayList(u8) = .empty;
    defer last_query.deinit(allocator);
    var context = ReplContext{
        .db = &db,
        .io = io,
        .scanner = &interactive_scanner,
        .last_query = &last_query,
        .session = Batch.Session.init(allocator, io, options.force),
    };
    while (true) {
        const done = try readOneLine(&context, stdout, stderr, env);
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
    try std.testing.expectEqualStrings("root@db.example:3307/app> ", with_database);

    const without_database = try connectionPrompt(std.testing.allocator, "", "localhost", 3306, "");
    defer std.testing.allocator.free(without_database);
    try std.testing.expectEqualStrings("localhost:3306/(none)> ", without_database);
}

test "connection banner shows connection and version details" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try renderConnectionBanner(&writer.writer, "MariaDB", 42, "12.3.2-MariaDB", "3.4.9");
    try std.testing.expectEqualStrings(
        \\Welcome to thysql.  Commands end with ; or \g.
        \\Your MariaDB connection id is 42
        \\Server version: 12.3.2-MariaDB
        \\Client library version: 3.4.9
        \\
        \\
    , writer.written());
}

test "history entry folds multiline query outside strings" {
    const entry = try formatHistoryEntry(std.testing.allocator, .{
        .sql = "select\n'kept\nnewline'\nfrom dual",
        .vertical = false,
    }, ";");
    defer std.testing.allocator.free(entry);

    try std.testing.expectEqualStrings("select 'kept\nnewline' from dual;", entry);
}

test "history entry ends with the delimiter in effect" {
    const entry = try formatHistoryEntry(std.testing.allocator, .{
        .sql = "create procedure p() begin select 1; end",
        .vertical = false,
    }, "$$");
    defer std.testing.allocator.free(entry);

    try std.testing.expectEqualStrings("create procedure p() begin select 1; end$$", entry);
}

test "history entry keeps vertical terminator" {
    const entry = try formatHistoryEntry(std.testing.allocator, .{
        .sql = "select 1",
        .vertical = true,
    }, ";");
    defer std.testing.allocator.free(entry);

    try std.testing.expectEqualStrings("select 1\\G", entry);
}

test "editor initial query prefers pending input over last query" {
    var scanner: Batch.Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    var last_query: std.ArrayList(u8) = .empty;
    defer last_query.deinit(std.testing.allocator);
    try last_query.appendSlice(std.testing.allocator, "select 1");

    try std.testing.expectEqualStrings("select 1", editorInitialQuery(&scanner, &last_query));

    try scanner.replacePending(std.testing.allocator, "select 2");
    try std.testing.expectEqualStrings("select 2", editorInitialQuery(&scanner, &last_query));
}

test "detect edit client command" {
    try std.testing.expect(isEditCommand("\\e"));
    try std.testing.expect(isEditCommand(" edit "));
    try std.testing.expect(isEditCommand("edit;"));
    try std.testing.expect(!isEditCommand("select '\\e';"));
    try std.testing.expect(!isEditCommand("edited"));
}

test "detect clear client command" {
    try std.testing.expect(isClearCommand("\\c"));
    try std.testing.expect(isClearCommand(" clear "));
    try std.testing.expect(isClearCommand("clear;"));
    try std.testing.expect(!isClearCommand("select '\\c';"));
    try std.testing.expect(!isClearCommand("cleared"));
}

test "editor command falls back past empty environment values" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqualStrings("vi", editorCommand(&env));
    try env.put("EDITOR", "");
    try env.put("VISUAL", "code -w");
    try std.testing.expectEqualStrings("code -w", editorCommand(&env));
    try env.put("EDITOR", "vim -f");
    try std.testing.expectEqualStrings("vim -f", editorCommand(&env));
}

test "trim right bytes keeps leading whitespace" {
    try std.testing.expectEqualStrings("  select 1", trimRightBytes("  select 1\r\n", "\r\n"));
    try std.testing.expectEqualStrings("  \nselect 1", trimRightBytes("  \nselect 1", "\r\n"));
}

test {
    _ = .{
        @import("batch.zig"),
        @import("completion.zig"),
        @import("isocline.zig"),
        @import("mysql.zig"),
        @import("options.zig"),
        @import("unicode.zig"),
    };
}
