const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Query = struct {
    sql: []const u8,
    vertical: bool,
    /// Line where the statement starts (1-based), for error messages.
    line: usize = 0,
};

pub fn parseQueryInput(line: []const u8) Query {
    var sql = std.mem.trim(u8, line, " \t\r\n");
    var vertical = false;

    if (sql.len >= 2 and sql[sql.len - 2] == '\\' and sql[sql.len - 1] == 'G') {
        vertical = true;
        sql = std.mem.trim(u8, sql[0 .. sql.len - 2], " \t\r\n");
    }

    return .{
        .sql = sql,
        .vertical = vertical,
    };
}

pub const Scanner = struct {
    pub const PromptKind = enum {
        main,
        continuation,
        single_quote,
        double_quote,
        backtick,
        block_comment,
    };

    const State = enum {
        normal,
        maybe_dash_comment,
        maybe_block_comment,
        maybe_command,
        single_quote,
        double_quote,
        backtick,
        line_comment,
        block_comment,
    };

    buffer: std.ArrayList(u8) = .empty,
    state: State = .normal,
    escaped: bool = false,
    block_comment_star: bool = false,

    pub fn deinit(self: *Scanner, allocator: Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn feed(self: *Scanner, allocator: Allocator, byte: u8) !bool {
        switch (self.state) {
            .normal => return self.feedNormal(allocator, byte),
            .maybe_dash_comment => {
                if (byte == '-') {
                    self.state = .line_comment;
                    try self.buffer.append(allocator, byte);
                    return false;
                }
                self.state = .normal;
                return self.feedNormal(allocator, byte);
            },
            .maybe_block_comment => {
                if (byte == '*') {
                    self.state = .block_comment;
                    self.block_comment_star = false;
                    try self.buffer.append(allocator, byte);
                    return false;
                }
                self.state = .normal;
                return self.feedNormal(allocator, byte);
            },
            .maybe_command => {
                if (byte == 'c') {
                    _ = self.buffer.pop();
                    self.reset();
                    return false;
                }
                if (byte == 'G') {
                    try self.buffer.append(allocator, byte);
                    self.state = .normal;
                    return true;
                }
                if (byte == 'g') {
                    _ = self.buffer.pop();
                    self.state = .normal;
                    return true;
                }

                self.state = .normal;
                return self.feedNormal(allocator, byte);
            },
            .single_quote, .double_quote => {
                try self.buffer.append(allocator, byte);
                if (self.escaped) {
                    self.escaped = false;
                    return false;
                }
                if (byte == '\\') {
                    self.escaped = true;
                } else if ((self.state == .single_quote and byte == '\'') or
                    (self.state == .double_quote and byte == '"'))
                {
                    self.state = .normal;
                }
                return false;
            },
            .backtick => {
                try self.buffer.append(allocator, byte);
                if (byte == '`') {
                    self.state = .normal;
                }
                return false;
            },
            .line_comment => {
                try self.buffer.append(allocator, byte);
                if (byte == '\n') {
                    self.state = .normal;
                }
                return false;
            },
            .block_comment => {
                try self.buffer.append(allocator, byte);
                if (self.block_comment_star and byte == '/') {
                    self.state = .normal;
                    self.block_comment_star = false;
                } else {
                    self.block_comment_star = byte == '*';
                }
                return false;
            },
        }
    }

    fn feedNormal(self: *Scanner, allocator: Allocator, byte: u8) !bool {
        switch (byte) {
            ';' => return true,
            '\'' => {
                self.state = .single_quote;
                self.escaped = false;
            },
            '"' => {
                self.state = .double_quote;
                self.escaped = false;
            },
            '`' => self.state = .backtick,
            '-' => self.state = .maybe_dash_comment,
            '/' => self.state = .maybe_block_comment,
            '\\' => self.state = .maybe_command,
            else => {},
        }
        try self.buffer.append(allocator, byte);
        return false;
    }

    pub fn pendingQuery(self: *Scanner) Query {
        return parseQueryInput(self.buffer.items);
    }

    pub fn promptKind(self: *const Scanner) PromptKind {
        return switch (self.state) {
            .normal, .maybe_dash_comment, .maybe_block_comment, .maybe_command, .line_comment => if (self.buffer.items.len == 0)
                .main
            else
                .continuation,
            .single_quote => .single_quote,
            .double_quote => .double_quote,
            .backtick => .backtick,
            .block_comment => .block_comment,
        };
    }

    pub fn reset(self: *Scanner) void {
        self.buffer.clearRetainingCapacity();
        self.state = .normal;
        self.escaped = false;
        self.block_comment_star = false;
    }

    pub fn replacePending(self: *Scanner, allocator: Allocator, input: []const u8) !void {
        self.reset();
        try self.buffer.appendSlice(allocator, input);
        self.state = .normal;
        self.escaped = false;
        self.block_comment_star = false;
        for (input) |byte| {
            self.scanPromptState(byte);
        }
    }

    fn scanPromptState(self: *Scanner, byte: u8) void {
        switch (self.state) {
            .normal => switch (byte) {
                '\'' => {
                    self.state = .single_quote;
                    self.escaped = false;
                },
                '"' => {
                    self.state = .double_quote;
                    self.escaped = false;
                },
                '`' => self.state = .backtick,
                '-' => self.state = .maybe_dash_comment,
                '/' => self.state = .maybe_block_comment,
                else => {},
            },
            .maybe_dash_comment => {
                if (byte == '-') {
                    self.state = .line_comment;
                } else {
                    self.state = .normal;
                    self.scanPromptState(byte);
                }
            },
            .maybe_block_comment => {
                if (byte == '*') {
                    self.state = .block_comment;
                    self.block_comment_star = false;
                } else {
                    self.state = .normal;
                    self.scanPromptState(byte);
                }
            },
            .maybe_command => self.state = .normal,
            .single_quote, .double_quote => {
                if (self.escaped) {
                    self.escaped = false;
                    return;
                }
                if (byte == '\\') {
                    self.escaped = true;
                } else if ((self.state == .single_quote and byte == '\'') or
                    (self.state == .double_quote and byte == '"'))
                {
                    self.state = .normal;
                }
            },
            .backtick => {
                if (byte == '`') {
                    self.state = .normal;
                }
            },
            .line_comment => {
                if (byte == '\n') {
                    self.state = .normal;
                }
            },
            .block_comment => {
                if (self.block_comment_star and byte == '/') {
                    self.state = .normal;
                    self.block_comment_star = false;
                } else {
                    self.block_comment_star = byte == '*';
                }
            },
        }
    }
};

pub fn stdinProgressTotal(stdin: std.Io.File, io: std.Io) ?u64 {
    const stat = stdin.stat(io) catch return null;
    if (stat.kind != .file or stat.size == 0) {
        return null;
    }
    return stat.size;
}

const Progress = struct {
    total_bytes: ?u64,
    /// Only true when stderr is a terminal. Otherwise nothing is drawn.
    enabled: bool = false,
    last_width: usize = 0,

    const bar_width = 30;

    fn render(self: *Progress, stderr: *std.Io.Writer, bytes_read: u64, query_count: u64, final: bool) !void {
        if (!self.enabled) {
            return;
        }

        var line_buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);

        if (self.total_bytes) |total| {
            const bounded_read = @min(bytes_read, total);
            const percent: u8 = @intCast(@divTrunc(@as(u128, bounded_read) * 100, total));
            const filled = @divTrunc(@as(usize, percent) * bar_width, 100);

            try writer.print("[", .{});
            for (0..bar_width) |i| {
                const char: u8 = if (i < filled)
                    '='
                else if (i == filled and percent < 100)
                    '>'
                else
                    '-';
                try writer.print("{c}", .{char});
            }
            try writer.print("] {}% {} quer{s}", .{
                percent,
                query_count,
                if (query_count == 1) "y" else "ies",
            });
        } else {
            try writer.print("{} bytes, {} quer{s}", .{
                bytes_read,
                query_count,
                if (query_count == 1) "y" else "ies",
            });
        }

        const rendered = writer.buffered();
        try stderr.print("\r{s}", .{rendered});
        if (self.last_width > rendered.len) {
            for (0..self.last_width - rendered.len) |_| {
                try stderr.print(" ", .{});
            }
        }
        if (final) {
            try stderr.print("\n", .{});
            self.last_width = 0;
        } else {
            self.last_width = rendered.len;
        }
        try stderr.flush();
    }
};

pub const RunOptions = struct {
    /// Total input size, when the input is a file. Used for the progress bar.
    progress_total: ?u64 = null,
    /// Draw the progress meter. Set this only when stderr is a terminal.
    show_progress: bool = false,
    /// Keep running after a statement fails. The exit status is still 1.
    force: bool = false,
};

const Session = struct {
    progress: Progress,
    force: bool,
    query_count: u64 = 0,
    bytes_read: u64 = 0,
    had_error: bool = false,
};

/// Runs one statement. Returns false when the run should stop.
fn runStatement(
    session: *Session,
    scanner: *Scanner,
    line: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), *std.Io.Writer, *std.Io.Writer, Query) anyerror!bool,
) !bool {
    var query = scanner.pendingQuery();
    query.line = line;
    defer scanner.reset();
    if (query.sql.len == 0) {
        return true;
    }

    const ok = try execute(context, stdout, stderr, query);
    session.query_count += 1;
    if (!ok) {
        session.had_error = true;
    }
    try session.progress.render(stderr, session.bytes_read, session.query_count, false);
    return ok or session.force;
}

/// Reads statements from `input` and runs each with `execute`. Returns 0 when
/// all statements succeeded, and 1 otherwise. Without `force`, the first
/// failing statement stops the run.
pub fn run(
    allocator: Allocator,
    input: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    run_options: RunOptions,
    context: anytype,
    comptime execute: fn (@TypeOf(context), *std.Io.Writer, *std.Io.Writer, Query) anyerror!bool,
) !u8 {
    var session = Session{
        .progress = .{ .total_bytes = run_options.progress_total, .enabled = run_options.show_progress },
        .force = run_options.force,
    };
    var read_buffer: [8192]u8 = undefined;
    var scanner: Scanner = .{};
    defer scanner.deinit(allocator);

    var line: usize = 1;
    var statement_line: usize = 0;
    var stopped = false;

    try session.progress.render(stderr, 0, 0, false);
    read_loop: while (true) {
        // readVec returns what is available now, so a terminal runs each line as soon as
        // it is entered. readSliceShort would wait until the buffer is full or EOF.
        var slices = [_][]u8{&read_buffer};
        const read = input.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return err,
        };
        if (read == 0) {
            continue;
        }

        session.bytes_read += read;
        for (read_buffer[0..read]) |byte| {
            // A statement starts at its first non-whitespace byte.
            if (statement_line == 0 and !std.ascii.isWhitespace(byte)) {
                statement_line = line;
            }
            if (byte == '\n') {
                line += 1;
            }

            if (try scanner.feed(allocator, byte)) {
                if (!try runStatement(&session, &scanner, statement_line, stdout, stderr, context, execute)) {
                    stopped = true;
                    break :read_loop;
                }
                statement_line = 0;
            } else if (scanner.buffer.items.len == 0) {
                // A client command such as \c cleared the pending input.
                statement_line = 0;
            }
        }
        try session.progress.render(stderr, session.bytes_read, session.query_count, false);
    }

    if (!stopped and scanner.pendingQuery().sql.len != 0) {
        _ = try runStatement(&session, &scanner, statement_line, stdout, stderr, context, execute);
    }

    try session.progress.render(stderr, session.bytes_read, session.query_count, true);
    return if (session.had_error) 1 else 0;
}

test "parse vertical query terminator" {
    var query = parseQueryInput("select 1\\G");
    try std.testing.expectEqualStrings("select 1", query.sql);
    try std.testing.expect(query.vertical);

    query = parseQueryInput("  select 1  \\G  ");
    try std.testing.expectEqualStrings("select 1", query.sql);
    try std.testing.expect(query.vertical);

    query = parseQueryInput("select 1;");
    try std.testing.expectEqualStrings("select 1;", query.sql);
    try std.testing.expect(!query.vertical);
}

test "scanner splits statements outside strings and comments" {
    const input =
        \\select 'a;b';
        \\-- ignore this ; in a line comment
        \\select "c;d";
        \\/* ignore this ; in a block comment */
        \\select `semi;name`;
    ;

    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    var statements: std.ArrayList([]u8) = .empty;
    defer {
        for (statements.items) |statement| {
            std.testing.allocator.free(statement);
        }
        statements.deinit(std.testing.allocator);
    }

    for (input) |byte| {
        if (try scanner.feed(std.testing.allocator, byte)) {
            const query = scanner.pendingQuery();
            try statements.append(std.testing.allocator, try std.testing.allocator.dupe(u8, query.sql));
            scanner.reset();
        }
    }

    const trailing_query = scanner.pendingQuery();
    if (trailing_query.sql.len != 0) {
        try statements.append(std.testing.allocator, try std.testing.allocator.dupe(u8, trailing_query.sql));
    }

    try std.testing.expectEqual(@as(usize, 3), statements.items.len);
    try std.testing.expectEqualStrings("select 'a;b'", statements.items[0]);
    try std.testing.expectEqualStrings("-- ignore this ; in a line comment\nselect \"c;d\"", statements.items[1]);
    try std.testing.expectEqualStrings("/* ignore this ; in a block comment */\nselect `semi;name`", statements.items[2]);
}

test "scanner splits slash command terminators outside strings" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    var saw_vertical = false;
    for ("select 1\\G") |byte| {
        if (try scanner.feed(std.testing.allocator, byte)) {
            saw_vertical = true;
            const query = scanner.pendingQuery();
            try std.testing.expectEqualStrings("select 1", query.sql);
            try std.testing.expect(query.vertical);
            scanner.reset();
        }
    }
    try std.testing.expect(saw_vertical);

    var saw_regular = false;
    for ("select 2\\g") |byte| {
        if (try scanner.feed(std.testing.allocator, byte)) {
            saw_regular = true;
            const query = scanner.pendingQuery();
            try std.testing.expectEqualStrings("select 2", query.sql);
            try std.testing.expect(!query.vertical);
            scanner.reset();
        }
    }
    try std.testing.expect(saw_regular);
}

test "scanner clears pending input with slash clear command" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    for ("select 1\\c") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqualStrings("", scanner.buffer.items);
    try std.testing.expectEqual(Scanner.PromptKind.main, scanner.promptKind());

    var saw_query = false;
    for ("select 2;") |byte| {
        if (try scanner.feed(std.testing.allocator, byte)) {
            saw_query = true;
            const query = scanner.pendingQuery();
            try std.testing.expectEqualStrings("select 2", query.sql);
            scanner.reset();
        }
    }
    try std.testing.expect(saw_query);
}

test "scanner keeps slash clear command inside strings" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    var saw_query = false;
    for ("select '\\c';") |byte| {
        if (try scanner.feed(std.testing.allocator, byte)) {
            saw_query = true;
            const query = scanner.pendingQuery();
            try std.testing.expectEqualStrings("select '\\c'", query.sql);
            scanner.reset();
        }
    }
    try std.testing.expect(saw_query);
}

test "scanner reports interactive prompt state" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    try std.testing.expectEqual(Scanner.PromptKind.main, scanner.promptKind());

    for ("select 1") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(Scanner.PromptKind.continuation, scanner.promptKind());
    scanner.reset();

    for ("select 'unterminated") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(Scanner.PromptKind.single_quote, scanner.promptKind());
    scanner.reset();

    for ("select \"unterminated") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(Scanner.PromptKind.double_quote, scanner.promptKind());
    scanner.reset();

    for ("select `unterminated") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(Scanner.PromptKind.backtick, scanner.promptKind());
    scanner.reset();

    for ("select /* unterminated") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(Scanner.PromptKind.block_comment, scanner.promptKind());
}

test "scanner replaces pending editor buffer and recomputes prompt state" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    try scanner.replacePending(std.testing.allocator, "select 'unterminated");
    try std.testing.expectEqualStrings("select 'unterminated", scanner.buffer.items);
    try std.testing.expectEqual(Scanner.PromptKind.single_quote, scanner.promptKind());

    try scanner.replacePending(std.testing.allocator, "select /* comment");
    try std.testing.expectEqualStrings("select /* comment", scanner.buffer.items);
    try std.testing.expectEqual(Scanner.PromptKind.block_comment, scanner.promptKind());

    try scanner.replacePending(std.testing.allocator, "select 1;");
    try std.testing.expectEqualStrings("select 1;", scanner.buffer.items);
    try std.testing.expectEqual(Scanner.PromptKind.continuation, scanner.promptKind());
}

const RecordingContext = struct {
    allocator: Allocator,
    lines: std.ArrayList(usize) = .empty,

    fn deinit(self: *RecordingContext) void {
        self.lines.deinit(self.allocator);
    }
};

/// Records each statement's start line. A statement that contains "bad" fails.
fn recordQuery(context: *RecordingContext, stdout: *std.Io.Writer, stderr: *std.Io.Writer, query: Query) anyerror!bool {
    _ = stdout;
    _ = stderr;
    try context.lines.append(context.allocator, query.line);
    return std.mem.indexOf(u8, query.sql, "bad") == null;
}

test "batch reports the line where each statement starts" {
    var input = std.Io.Reader.fixed("\n\nselect 1;\n  select\n2;\nselect 3;\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{}, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4, 6 }, context.lines.items);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "batch stops at the first error without force" {
    var input = std.Io.Reader.fixed("select 1;\nbad;\nselect 3;\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{}, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, context.lines.items);
}

test "batch keeps going after errors with force and still exits 1" {
    var input = std.Io.Reader.fixed("select 1;\nbad;\nselect 3;\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{ .force = true }, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, context.lines.items);
}
