//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const C = @import("mysql_c");
const Mysql = @import("mysql.zig");
const Batch = @import("batch.zig");
const ClientCommand = @import("client_command.zig");
const Client = @import("client.zig");
const Completion = @import("completion.zig");
const Options = @import("options.zig");
const OptionFile = @import("option_file.zig");
const Prompt = @import("prompt.zig");
const Readline = @import("readline.zig");
const SqlCompletion = @import("sql_completion.zig");
pub const Unicode = @import("unicode.zig");

/// Settings and state that only the interactive client has. Batch input runs without
/// them, so the client commands take them as null. Reconnecting is interactive-only, as
/// in mysql.cc, which turns it off for batch input.
const Repl = struct {
    names: *SqlCompletion.Names,
    prompt: *Prompt.State,
    history_ignore: *const Readline.Ignore,
    auto_rehash: bool,
    reconnect: bool,
    /// --silent: the notice about loading names is not printed.
    silent: bool,
};

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

/// Removes the backticks around a database name given to `use`.
fn unquoteName(name: []const u8) []const u8 {
    if (name.len >= 2 and name[0] == '`' and name[name.len - 1] == '`') {
        return name[1 .. name.len - 1];
    }
    return name;
}

/// Prints the connection id and database, as mysql.cc's com_connect does.
fn renderConnectionInfo(out: *std.Io.Writer, db: *Mysql.DB) !void {
    const database = if (db.database.len == 0) "*** NONE ***" else db.database;
    try out.print("Connection id:    {d}\nCurrent database: {s}\n\n", .{ db.connectionId(), database });
}

/// Loads the names for completion when auto-rehash is on. The notice is printed on connect
/// and on `use`, as mysql.cc does, unless --silent is given.
fn loadNames(repl: *const Repl, db: *Mysql.DB, out: *std.Io.Writer, notice: bool) !void {
    if (!repl.auto_rehash) {
        return;
    }
    const tables = try repl.names.load(db);
    if (notice and tables > 0 and !repl.silent) {
        try out.print("Reading table information for completion of table and column names\n" ++
            "You can turn off this feature to get a quicker startup with -A\n\n", .{});
    }
}

/// Reconnects after the server has gone away, with mysql.cc's messages: the notice, then the
/// connection id and database, then the names when auto-rehash is on. Returns false after
/// printing the failure when the connection cannot be made.
fn reconnectSession(db: *Mysql.DB, out: *std.Io.Writer, repl: *Repl) !bool {
    try out.print("No connection. Trying to reconnect...\n", .{});
    db.reconnect() catch |err| switch (err) {
        Mysql.DBError.ConnectError => {
            try db.renderConnectFailure(out, null);
            try out.print("ERROR: Can't connect to the server\n", .{});
            return false;
        },
        else => return err,
    };
    try renderConnectionInfo(out, db);
    try loadNames(repl, db, out, false);
    return true;
}

/// Whether a failed statement should trigger a reconnect: only in the interactive client,
/// with reconnect on, and only when the connection was lost.
fn canReconnect(db: *Mysql.DB, repl: ?*const Repl) bool {
    const session = repl orelse return false;
    return session.reconnect and Mysql.isLostConnection(db.lastErrno());
}

/// Selects `database`. A lost connection is reconnected once, and the select is tried again.
/// Errors are printed with the batch line number when `line` is set. Returns false after printing.
fn selectDatabase(db: *Mysql.DB, out: *std.Io.Writer, err_out: *std.Io.Writer, line: ?usize, repl: ?*Repl, database: [:0]const u8) !bool {
    var retried = false;
    while (true) {
        if (db.selectDatabase(database)) |_| {
            return true;
        } else |err| {
            if (err != Mysql.DBError.ExecError) {
                return err;
            }
        }
        if (!retried and canReconnect(db, repl)) {
            retried = true;
            // mysql.cc prints nothing for the lost connection itself, only the reconnect.
            if (!try reconnectSession(db, out, repl.?)) {
                return false;
            }
            continue;
        }
        if (line) |number| {
            try db.renderLastErrorAt(err_out, number);
        } else {
            try db.renderLastError(err_out);
        }
        return false;
    }
}

/// Runs `use <name>`. Errors go to `err_out`, with the line number when `line` is set (batch input).
fn useDatabase(
    db: *Mysql.DB,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    line: ?usize,
    repl: ?*Repl,
    arg: []const u8,
) !bool {
    if (arg.len == 0) {
        try err_out.print("ERROR: USE must be followed by a database name\n", .{});
        return false;
    }

    const name = unquoteName(arg);
    const database_z = try db.allocator.dupeSentinel(u8, name, 0);
    defer db.allocator.free(database_z);

    // As in mysql.cc, names are loaded only when the database changes.
    const changed = !std.mem.eql(u8, db.database, name);
    if (!try selectDatabase(db, out, err_out, line, repl, database_z)) {
        return false;
    }

    if (repl) |session| {
        if (changed) {
            try loadNames(session, db, out, true);
        }
        try out.print("Database changed\n", .{});
    }
    return true;
}

/// Runs `connect [db [host]]`. With no arguments it reconnects to the current database and
/// host, and the names are not reloaded. As in mysql.cc, a failed connect leaves the old one open.
fn connectCommand(db: *Mysql.DB, out: *std.Io.Writer, err_out: *std.Io.Writer, line: ?usize, repl: ?*Repl, arg: []const u8) !bool {
    var words = std.mem.tokenizeAny(u8, arg, " \t");
    const database = words.next();
    const host = words.next();

    db.connectTo(database, host) catch |err| switch (err) {
        Mysql.DBError.ConnectError => {
            try db.renderConnectFailure(err_out, line);
            return false;
        },
        else => return err,
    };
    if (repl) |session| {
        try renderConnectionInfo(out, db);
        if (database != null) {
            try loadNames(session, db, out, true);
        }
    }
    return true;
}

/// Runs `prompt [format]`. With no format, the prompt goes back to the default. The
/// prompt only shows in the interactive client, so batch input ignores it.
fn promptCommand(out: *std.Io.Writer, repl: ?*Repl, text: []const u8) !void {
    const session = repl orelse return;
    if (text.len == 0) {
        session.prompt.reset();
        try out.print("Returning to default PROMPT of {s}\n", .{session.prompt.defaultText()});
    } else {
        try session.prompt.set(text);
        try out.print("PROMPT set to '{s}'\n", .{text});
    }
}

/// Runs a client command from the REPL or batch input. `repl` is null for batch input.
/// `error.ClientQuit` ends the session.
fn runClientCommand(
    client: *Client,
    db: *Mysql.DB,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    line: ?usize,
    repl: ?*Repl,
    delimiter: []const u8,
    command: ClientCommand.Command,
) !bool {
    switch (command.kind) {
        .quit => return error.ClientQuit,
        .help => {
            if (command.arg.len == 0) {
                try ClientCommand.renderHelp(out);
            } else {
                try out.print("Server-side help is not supported. Type help for the client commands.\n", .{});
            }
        },
        .status => try client.renderStatus(db, out, delimiter),
        .use => return try useDatabase(db, out, err_out, line, repl, command.arg),
        .connect => return try connectCommand(db, out, err_out, line, repl, command.arg),
        .prompt => try promptCommand(out, repl, command.rest),
        // `rehash` loads the names whatever auto-rehash says, and prints nothing, as in mysql.cc.
        .rehash => if (repl) |session| {
            _ = try session.names.load(db);
        },
        .print => try Client.renderPrint(out, ""),
        .pager => try client.cmdPager(out, command.arg),
        .nopager => try client.cmdNopager(out),
        .tee => try client.cmdTee(out, command.arg),
        .notee => try client.cmdNotee(out),
        .warnings => try client.cmdWarnings(out, true),
        .nowarnings => try client.cmdWarnings(out, false),
    }
    return true;
}

/// Renders one result set. With a pager set, it goes through the pager. A pager that exits
/// early makes the writes fail, which is not an error for the session.
fn renderResult(client: *Client, result: [*c]C.struct_st_mysql_res, vertical: bool, elapsed_ns: i96, warnings: u32) !void {
    var sink: Client.ResultSink = undefined;
    try sink.open(client);
    defer sink.close();

    const out = sink.writer();
    const rendered = if (vertical)
        Mysql.render_result_vertical_timed_with_warnings(out, result, elapsed_ns, warnings)
    else
        Mysql.render_result_timed_with_warnings(out, result, elapsed_ns, warnings);
    rendered catch |err| {
        if (err == error.WriteFailed and sink.isPiped()) {
            return;
        }
        return err;
    };
}

/// Runs one statement for the REPL. As in mysql.cc, a lost connection prints the error,
/// reconnects, and runs the statement once more. Returns null after the error is printed.
fn execReplStatement(context: *ReplContext, stdout: *std.Io.Writer, sql: []const u8) !?Mysql.ExecResult {
    const db = context.db;
    var retried = false;
    while (true) {
        if (db.exec(sql)) |result| {
            return result;
        } else |err| switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {},
            else => return err,
        }

        try db.renderLastError(stdout);
        if (retried or !canReconnect(db, &context.repl)) {
            return null;
        }
        retried = true;
        if (!try reconnectSession(db, stdout, &context.repl)) {
            return null;
        }
    }
}

/// Runs one SQL statement from the REPL and renders its result sets. Errors and warnings go to `stdout`.
fn executeQuery(context: *ReplContext, stdout: *std.Io.Writer, query: Batch.Query) !bool {
    if (query.sql.len == 0) {
        return true;
    }
    const client = context.client;
    const db = context.db;

    const start = std.Io.Clock.Timestamp.now(context.io, .awake);
    beginInterruptibleQuery();
    defer endInterruptibleQuery();

    var exec_result = (try execReplStatement(context, stdout, query.sql)) orelse {
        try client.afterStatement(db, stdout, 0, db.lastErrno());
        return false;
    };

    var warnings: u32 = 0;
    while (true) {
        const elapsed_ns = start.durationTo(std.Io.Clock.Timestamp.now(context.io, .awake)).raw.nanoseconds;
        switch (exec_result) {
            .result => |result| {
                defer Mysql.freeResult(result);
                warnings = db.warningCount();
                try renderResult(client, result, query.vertical, elapsed_ns, warnings);
            },
            .ok => |ok| {
                warnings = ok.warnings;
                try Mysql.render_ok_timed(stdout, ok, elapsed_ns);
            },
        }

        exec_result = (db.nextResult() catch |err| {
            switch (err) {
                Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                    const error_code = db.lastErrno();
                    try db.renderLastError(stdout);
                    try client.afterStatement(db, stdout, warnings, error_code);
                    return false;
                },
                else => return err,
            }
        }) orelse break;
    }

    try client.afterStatement(db, stdout, warnings, 0);
    return true;
}

/// The main prompt. With a format from --prompt, MYSQL_PS1, or `prompt`, it is rendered with
/// mysql.cc's escapes. Otherwise it is the built-in connection prompt.
fn mainPrompt(context: *ReplContext, delimiter: []const u8) ![:0]u8 {
    const db = context.db;
    const allocator = db.allocator;
    const format = context.repl.prompt.activeFormat() orelse {
        return connectionPrompt(allocator, db.user, db.host, db.port, db.database);
    };

    // USER() is a query, so it runs only when the format asks for a user.
    const needs_user = std.mem.indexOf(u8, format, "\\u") != null or std.mem.indexOf(u8, format, "\\U") != null;
    const user_row = if (needs_user) try db.firstRowCopy(allocator, "select USER()") else null;
    defer if (user_row) |row| Mysql.freeRowCopy(allocator, row);
    const full_user: []const u8 = if (user_row) |row| (row[0] orelse "") else "";

    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname: []const u8 = std.posix.gethostname(&hostname_buffer) catch "";

    return Prompt.render(allocator, format, .{
        .full_user = full_user,
        .host_info = db.hostInfo(),
        .hostname = hostname,
        .port = db.port,
        .socket = db.socket,
        .database = db.database,
        .server_name = db.serverName(),
        .server_version = db.serverVersion(),
        .delimiter = delimiter,
    }, &context.repl.prompt.counter, Prompt.clockNow());
}

fn interactivePrompt(context: *ReplContext, scanner: *const Batch.Scanner) ![:0]u8 {
    const allocator = context.db.allocator;
    return switch (scanner.promptKind()) {
        .main => try mainPrompt(context, scanner.delimiterText()),
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

fn addQueryToHistory(allocator: Allocator, query: Batch.Query, delimiter: []const u8, readline: *Readline.Session, ignore: *const Readline.Ignore) !void {
    if (query.sql.len == 0) {
        return;
    }

    const entry = try formatHistoryEntry(allocator, query, delimiter);
    defer allocator.free(entry);
    readline.addHistory(ignore, entry);
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
    client: *Client,
    repl: Repl,
    readline: *Readline.Session,
};

/// Runs one statement typed at the prompt. Errors are printed, and the REPL keeps going.
/// Statements from a sourced file are run, but they are not added to history.
fn executeReplQuery(context: *ReplContext, stdout: *std.Io.Writer, stderr: *std.Io.Writer, query: Batch.Query) !bool {
    _ = stderr;
    const allocator = context.db.allocator;
    const command = ClientCommand.parse(query.sql);
    if (context.session.depth == 0) {
        if (command == null) {
            try rememberLastQuery(allocator, context.last_query, query);
        }
        try addQueryToHistory(allocator, query, context.scanner.delimiterText(), context.readline, context.repl.history_ignore);
    }
    if (command) |client_command| {
        return try runClientCommand(context.client, context.db, stdout, stdout, null, &context.repl, context.scanner.delimiterText(), client_command);
    }
    return try executeQuery(context, stdout, query);
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
    const prompt = try interactivePrompt(context, scanner);
    defer db.allocator.free(prompt);

    const line = switch (try context.readline.one(prompt)) {
        .line => |text| text,
        .cancelled => {
            // Ctrl-C drops the whole pending statement, as \c does, so the next prompt is the primary one.
            scanner.reset();
            return false;
        },
        .eof => return true,
    };
    defer db.allocator.free(line);
    context.client.echoInput(prompt, line);
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

    // A client command at the start of a line runs at once, without a delimiter, as in mysql.cc.
    if (scanner.atStatementStart() and std.mem.indexOf(u8, line, scanner.delimiterText()) == null) {
        if (ClientCommand.parse(line)) |command| {
            _ = runClientCommand(context.client, db, stdout, stdout, null, &context.repl, scanner.delimiterText(), command) catch |err| switch (err) {
                error.ClientQuit => return true,
                else => return err,
            };
            try stdout.flush();
            return false;
        }
    }

    feedInteractiveInput(context, stdout, stderr, line, true) catch |err| switch (err) {
        error.ClientQuit => return true,
        else => return err,
    };
    try stdout.flush();
    return false;
}

const BatchContext = struct {
    db: *Mysql.DB,
    options: *const Options.Options,
    stdin_is_tty: bool,
    client: *Client,
};

/// Runs one batch statement. Results go to stdout, and errors go to stderr
/// with the statement's line number. Returns false on error.
fn executeBatchQuery(context: BatchContext, stdout: *std.Io.Writer, stderr: *std.Io.Writer, query: Batch.Query) !bool {
    const db = context.db;
    if (query.sql.len == 0) {
        return true;
    }

    if (ClientCommand.parse(query.sql)) |command| {
        return try runClientCommand(context.client, db, stdout, stderr, query.line, null, context.options.delimiter, command);
    }

    var exec_result = db.exec(query.sql) catch |err| {
        switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                const error_code = db.lastErrno();
                try db.renderLastErrorAt(stderr, query.line);
                try context.client.afterStatement(db, stdout, 0, error_code);
                return false;
            },
            else => return err,
        }
    };

    const format = context.options.resultFormat(context.stdin_is_tty, query.vertical);
    const column_names = context.options.showColumnNames(format);
    var warnings: u32 = 0;
    while (true) {
        switch (exec_result) {
            .result => |result| {
                defer Mysql.freeResult(result);
                warnings = db.warningCount();
                try Mysql.render_script_result(stdout, result, format, column_names, context.options.raw);
            },
            .ok => |ok| warnings = ok.warnings,
        }

        exec_result = (db.nextResult() catch |err| {
            switch (err) {
                Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                    const error_code = db.lastErrno();
                    try db.renderLastErrorAt(stderr, query.line);
                    try context.client.afterStatement(db, stdout, warnings, error_code);
                    return false;
                },
                else => return err,
            }
        }) orelse break;
    }

    try context.client.afterStatement(db, stdout, warnings, 0);
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
    client: *Client,
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
        .client = client,
    };
    // `quit` ends the input with success, as in mysql.cc.
    return Batch.run(db.allocator, input, stdout, stderr, run_options, context, executeBatchQuery) catch |err| switch (err) {
        error.ClientQuit => 0,
        else => return err,
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

    if (args.items.len > 1 and std.mem.eql(u8, args.items[1], "complete")) {
        return try Completion.run(allocator, io, stdout, stderr, args.items, env);
    }

    // Option files come before the command line, as in mysql.cc's load_defaults.
    var loaded = OptionFile.load(allocator, io, env, args.items, stderr) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.OptionFileFailed => return 1,
    };
    defer loaded.deinit();
    if (loaded.print_defaults) {
        try OptionFile.renderPrintDefaults(stdout, args.items[0], loaded.settings, args.items[loaded.next..]);
        try stdout.flush();
        return 0;
    }

    var options = Options.parseWithSettings(allocator, args.items, loaded.next, env, loaded.settings) catch |err| {
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

    var db = Mysql.DB.init(allocator, .{
        .host = options.host,
        .user = options.user,
        .password = options.password,
        .database = options.database,
        .port = options.port,
        .socket = options.socket,
        .protocol = options.protocol,
        .tls = options.tls,
    }) catch |err| switch (err) {
        // connect() has already printed the server's error message.
        error.ConnectError => return 1,
        else => return err,
    };
    defer db.close();

    var client = Client.init(allocator, io, stdout, options.isBatch(stdin_is_tty));
    defer client.deinit();
    client.show_warnings = options.show_warnings;

    if (options.isBatch(stdin_is_tty)) {
        return try runBatch(io, stdin, stdin_is_tty, stderr_is_tty, stdout, stderr, &db, &options, &client);
    }

    // The pager and the tee file are for interactive use only, as in mysql.cc.
    try client.configurePager(options.pager, env.get("PAGER"));
    if (options.tee) |path| {
        try client.cmdTee(stdout, path);
    }

    // Everything the REPL prints goes through this, so the tee file gets a copy.
    var repl_out = Client.Mirror.init(stdout, &client);
    const out = repl_out.writer();

    // The prompt comes from --prompt, else MYSQL_PS1, else the built-in connection prompt.
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var prompt_state = try Prompt.State.init(allocator, env.get("MYSQL_PS1"), options.prompt);
    defer prompt_state.deinit();
    var history_ignore = try Readline.Ignore.init(allocator, env.get("MYSQL_HISTIGNORE"));
    defer history_ignore.deinit();
    var repl: Repl = .{
        .names = &names,
        .prompt = &prompt_state,
        .history_ignore = &history_ignore,
        .auto_rehash = options.auto_rehash,
        .reconnect = options.reconnect,
        .silent = options.silent > 0,
    };

    const readline = try Readline.Session.setup(allocator, io, env, out, &names);
    defer readline.deinit();
    // Names load before the banner, as mysql.cc does at connect.
    try loadNames(&repl, &db, out, true);
    try renderConnectionBanner(out, db.serverName(), db.connectionId(), db.serverVersion(), Mysql.clientInfo());

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
        .client = &client,
        .repl = repl,
        .readline = readline,
    };
    while (true) {
        const done = try readOneLine(&context, out, stderr, env);
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

test "use strips backticks around a database name" {
    try std.testing.expectEqualStrings("my-db", unquoteName("`my-db`"));
    try std.testing.expectEqualStrings("test", unquoteName("test"));
    try std.testing.expectEqualStrings("`", unquoteName("`"));
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

test "ctrl-c at a continuation prompt discards the pending statement" {
    // readOneLine calls scanner.reset() when the line is cancelled. The next prompt must then be the main one.
    var scanner: Batch.Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    for ("select 1") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(Batch.Scanner.PromptKind.continuation, scanner.promptKind());

    scanner.reset();
    try std.testing.expectEqual(Batch.Scanner.PromptKind.main, scanner.promptKind());
    try std.testing.expectEqualStrings("", scanner.buffer.items);
}

test {
    _ = .{
        @import("batch.zig"),
        @import("client.zig"),
        @import("client_command.zig"),
        @import("completion.zig"),
        @import("history_file.zig"),
        @import("mysql.zig"),
        @import("option_file.zig"),
        @import("options.zig"),
        @import("prompt.zig"),
        @import("readline.zig"),
        @import("sql_completion.zig"),
        @import("unicode.zig"),
    };
}
