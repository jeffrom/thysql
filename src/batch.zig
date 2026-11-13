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

/// mysql.cc keeps the delimiter in a 16-byte buffer, so a longer one is cut to 15 bytes.
pub const max_delimiter_len = 15;

pub const DelimiterError = error{ EmptyDelimiter, BackslashInDelimiter };

/// Checks a delimiter as mysql.cc does: it cannot be empty or contain a backslash.
pub fn checkDelimiter(text: []const u8) DelimiterError![]const u8 {
    if (text.len == 0) {
        return error.EmptyDelimiter;
    }
    if (std.mem.indexOfScalar(u8, text, '\\') != null) {
        return error.BackslashInDelimiter;
    }
    return text[0..@min(text.len, max_delimiter_len)];
}

/// Client commands that start a statement and run to the end of their line.
pub const Command = enum { delimiter, source };

const default_delimiter_bytes = blk: {
    var bytes: [max_delimiter_len]u8 = @splat(0);
    bytes[0] = ';';
    break :blk bytes;
};

const Delimiter = struct {
    bytes: [max_delimiter_len]u8 = default_delimiter_bytes,
    len: usize = 1,

    fn slice(self: *const Delimiter) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn isLiteral(state: Scanner.State) bool {
    return switch (state) {
        .single_quote, .double_quote, .backtick, .line_comment, .block_comment => true,
        else => false,
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
        /// At the start of a statement, matching the word of a client command.
        keyword,
        maybe_dash_comment,
        maybe_block_comment,
        maybe_command,
        single_quote,
        double_quote,
        backtick,
        line_comment,
        block_comment,
        /// Inside a client command line. The newline ends it.
        command_line,
    };

    const Keyword = struct { text: []const u8, command: Command };
    const keywords = [_]Keyword{
        .{ .text = "delimiter", .command = .delimiter },
        .{ .text = "source", .command = .source },
        .{ .text = "\\d", .command = .delimiter },
        .{ .text = "\\.", .command = .source },
    };
    const all_keywords: u8 = (1 << keywords.len) - 1;

    buffer: std.ArrayList(u8) = .empty,
    state: State = .normal,
    escaped: bool = false,
    block_comment_star: bool = false,
    delimiter: Delimiter = .{},
    /// True once the statement has a non-blank byte. Client commands are only recognized before that.
    started: bool = false,
    /// Keyword candidates that still match, as bits into `keywords`, and how many bytes they matched.
    keyword_mask: u8 = 0,
    keyword_len: usize = 0,
    command: Command = .delimiter,
    /// Where the argument of a client command starts in `buffer`.
    command_arg_start: usize = 0,
    /// A delimiter can only start at or after this index of `buffer`. Earlier bytes may be a quote or comment.
    literal_end: usize = 0,

    pub fn deinit(self: *Scanner, allocator: Allocator) void {
        self.buffer.deinit(allocator);
    }

    pub fn delimiterText(self: *const Scanner) []const u8 {
        return self.delimiter.slice();
    }

    /// Sets the delimiter that ends statements, as --delimiter and DELIMITER do.
    pub fn setDelimiter(self: *Scanner, text: []const u8) DelimiterError!void {
        const checked = try checkDelimiter(text);
        @memcpy(self.delimiter.bytes[0..checked.len], checked);
        self.delimiter.len = checked.len;
    }

    pub fn feed(self: *Scanner, allocator: Allocator, byte: u8) Allocator.Error!bool {
        if (self.canStartDelimiter() and self.endsWithDelimiter(byte)) {
            // The delimiter's earlier bytes are already buffered. Its last byte is never stored.
            self.buffer.shrinkRetainingCapacity(self.buffer.items.len + 1 - self.delimiter.len);
            return true;
        }

        const was_literal = isLiteral(self.state);
        const done = try self.feedState(allocator, byte);
        if (was_literal and !isLiteral(self.state)) {
            self.literal_end = self.buffer.items.len;
        }
        return done;
    }

    fn canStartDelimiter(self: *const Scanner) bool {
        return switch (self.state) {
            .normal, .keyword, .maybe_dash_comment, .maybe_block_comment, .maybe_command => true,
            else => false,
        };
    }

    /// True when the buffered bytes followed by `byte` end with the delimiter, outside quotes and comments.
    fn endsWithDelimiter(self: *const Scanner, byte: u8) bool {
        const delimiter = self.delimiter.slice();
        const items = self.buffer.items;
        if (items.len + 1 < delimiter.len) {
            return false;
        }
        const start = items.len + 1 - delimiter.len;
        if (start < self.literal_end) {
            return false;
        }
        for (delimiter, 0..) |want, i| {
            const pos = start + i;
            const got = if (pos < items.len) items[pos] else byte;
            if (got != want) {
                return false;
            }
        }
        return true;
    }

    fn feedState(self: *Scanner, allocator: Allocator, byte: u8) Allocator.Error!bool {
        switch (self.state) {
            .normal => {
                if (!self.started and !std.ascii.isWhitespace(byte)) {
                    self.started = true;
                    self.state = .keyword;
                    self.keyword_mask = all_keywords;
                    self.keyword_len = 0;
                    return self.feedKeyword(allocator, byte);
                }
                return self.feedNormal(allocator, byte);
            },
            .keyword => return self.feedKeyword(allocator, byte),
            .command_line => {
                if (byte == '\n') {
                    return true;
                }
                try self.buffer.append(allocator, byte);
                return false;
            },
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

    /// Feeds one byte while matching a client command word. Matching is case-insensitive.
    fn feedKeyword(self: *Scanner, allocator: Allocator, byte: u8) Allocator.Error!bool {
        if (self.completedKeyword()) |command| {
            // The word must end at whitespace, or it is ordinary SQL such as "sourcery".
            if (!std.ascii.isWhitespace(byte)) {
                return self.leaveKeyword(allocator, byte);
            }
            self.state = .command_line;
            self.command = command;
            self.command_arg_start = self.buffer.items.len;
            self.keyword_mask = 0;
            self.keyword_len = 0;
            if (byte == '\n') {
                return true;
            }
            try self.buffer.append(allocator, byte);
            return false;
        }

        var matched: u8 = 0;
        for (keywords, 0..) |keyword, i| {
            const bit = @as(u8, 1) << @intCast(i);
            if (self.keyword_mask & bit != 0 and self.keyword_len < keyword.text.len and
                std.ascii.toLower(keyword.text[self.keyword_len]) == std.ascii.toLower(byte))
            {
                matched |= bit;
            }
        }
        if (matched == 0) {
            return self.leaveKeyword(allocator, byte);
        }
        try self.buffer.append(allocator, byte);
        self.keyword_len += 1;
        self.keyword_mask = matched;
        return false;
    }

    fn completedKeyword(self: *const Scanner) ?Command {
        for (keywords, 0..) |keyword, i| {
            const bit = @as(u8, 1) << @intCast(i);
            if (self.keyword_mask & bit != 0 and self.keyword_len == keyword.text.len) {
                return keyword.command;
            }
        }
        return null;
    }

    /// Ends keyword matching without a command. The bytes matched so far stay in the buffer as SQL.
    fn leaveKeyword(self: *Scanner, allocator: Allocator, byte: u8) Allocator.Error!bool {
        // A lone backslash starts a backslash command such as \G or \c.
        const lone_backslash = self.keyword_len == 1 and self.buffer.items[self.buffer.items.len - 1] == '\\';
        self.state = if (lone_backslash) .maybe_command else .normal;
        self.keyword_mask = 0;
        self.keyword_len = 0;
        return self.feed(allocator, byte);
    }

    fn feedNormal(self: *Scanner, allocator: Allocator, byte: u8) Allocator.Error!bool {
        switch (byte) {
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

    /// The client command that the buffered line holds, if the statement is one.
    pub fn pendingCommand(self: *const Scanner) ?Command {
        return if (self.state == .command_line) self.command else null;
    }

    /// The argument of the pending client command, without surrounding whitespace.
    pub fn commandArg(self: *const Scanner) []const u8 {
        return std.mem.trim(u8, self.buffer.items[self.command_arg_start..], " \t\r\n");
    }

    pub fn promptKind(self: *const Scanner) PromptKind {
        return switch (self.state) {
            .normal, .keyword, .maybe_dash_comment, .maybe_block_comment, .maybe_command, .line_comment, .command_line => if (self.buffer.items.len == 0)
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
        self.started = false;
        self.keyword_mask = 0;
        self.keyword_len = 0;
        self.literal_end = 0;
    }

    pub fn replacePending(self: *Scanner, allocator: Allocator, input: []const u8) Allocator.Error!void {
        self.reset();
        try self.buffer.appendSlice(allocator, input);
        for (input, 0..) |byte, i| {
            const was_literal = isLiteral(self.state);
            self.scanPromptState(byte);
            if (was_literal and !isLiteral(self.state)) {
                self.literal_end = i + 1;
            }
            if (!std.ascii.isWhitespace(byte)) {
                self.started = true;
            }
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
            // Only feed() enters these states, so an editor buffer never reaches them.
            .keyword, .command_line => {},
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
    /// The delimiter at the start of the input, as set by --delimiter.
    delimiter: []const u8 = ";",
    /// Needed by `source`, which opens files. Without it, `source` fails.
    io: ?std.Io = null,
};

/// How deeply `source` may nest. This stops a file that sources itself.
pub const max_source_depth = 16;

/// State shared by the top-level input and every sourced file.
pub const Session = struct {
    allocator: Allocator,
    io: ?std.Io,
    force: bool,
    progress: Progress = .{ .total_bytes = null },
    depth: usize = 0,
    query_count: u64 = 0,
    bytes_read: u64 = 0,
    had_error: bool = false,

    pub fn init(allocator: Allocator, io: ?std.Io, force: bool) Session {
        return .{ .allocator = allocator, .io = io, .force = force };
    }

    fn renderProgress(self: *Session, stderr: *std.Io.Writer, final: bool) !void {
        // Only the top-level input has a meter. A sourced file has its own size.
        if (self.depth != 0) {
            return;
        }
        try self.progress.render(stderr, self.bytes_read, self.query_count, final);
    }
};

/// Records a failure. Returns whether the input may keep going.
fn failStatement(session: *Session) bool {
    session.had_error = true;
    return session.force;
}

/// Runs one completed statement or client command. Returns false when the input should stop.
pub fn runStatement(
    session: *Session,
    scanner: *Scanner,
    line: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), *std.Io.Writer, *std.Io.Writer, Query) anyerror!bool,
) anyerror!bool {
    defer scanner.reset();
    if (scanner.pendingCommand()) |command| {
        return runCommand(session, scanner, command, line, stdout, stderr, context, execute);
    }

    var query = scanner.pendingQuery();
    query.line = line;
    if (query.sql.len == 0) {
        return true;
    }

    const ok = try execute(context, stdout, stderr, query);
    session.query_count += 1;
    if (!ok) {
        session.had_error = true;
    }
    try session.renderProgress(stderr, false);
    return ok or session.force;
}

fn runCommand(
    session: *Session,
    scanner: *Scanner,
    command: Command,
    line: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), *std.Io.Writer, *std.Io.Writer, Query) anyerror!bool,
) anyerror!bool {
    switch (command) {
        .delimiter => {
            scanner.setDelimiter(scanner.commandArg()) catch |err| {
                const message = switch (err) {
                    error.EmptyDelimiter => "DELIMITER must be followed by a 'delimiter' character or string",
                    error.BackslashInDelimiter => "DELIMITER cannot contain a backslash character",
                };
                try stderr.print("ERROR: {s} at line {d}\n", .{ message, line });
                return failStatement(session);
            };
            return true;
        },
        .source => return runSource(session, scanner, scanner.commandArg(), line, stdout, stderr, context, execute),
    }
}

fn runSource(
    session: *Session,
    scanner: *Scanner,
    path: []const u8,
    line: usize,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), *std.Io.Writer, *std.Io.Writer, Query) anyerror!bool,
) anyerror!bool {
    if (path.len == 0) {
        try stderr.print("ERROR: Usage: \\. <filename> | source <filename> at line {d}\n", .{line});
        return failStatement(session);
    }
    const io = session.io orelse {
        try stderr.print("ERROR: source is not available here at line {d}\n", .{line});
        return failStatement(session);
    };
    if (session.depth >= max_source_depth) {
        try stderr.print("ERROR: source is nested more than {d} levels deep at line {d}\n", .{ max_source_depth, line });
        return failStatement(session);
    }

    var file = std.Io.Dir.openFile(.cwd(), io, path, .{}) catch |err| {
        try stderr.print("ERROR: Cannot open file '{s}': {s} at line {d}\n", .{ path, @errorName(err), line });
        return failStatement(session);
    };
    defer file.close(io);
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);

    // As in mysql.cc, the delimiter carries into the file, and a change inside the file stays after it.
    var nested: Scanner = .{ .delimiter = scanner.delimiter };
    defer nested.deinit(session.allocator);
    session.depth += 1;
    defer session.depth -= 1;
    const stopped = try runInput(session, &nested, &file_reader.interface, stdout, stderr, context, execute);
    scanner.delimiter = nested.delimiter;
    return !stopped;
}

/// Feeds `input` through `scanner` and runs each statement and client command. Returns true when a failure stopped the input.
fn runInput(
    session: *Session,
    scanner: *Scanner,
    input: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), *std.Io.Writer, *std.Io.Writer, Query) anyerror!bool,
) anyerror!bool {
    var read_buffer: [8192]u8 = undefined;
    var line: usize = 1;
    var statement_line: usize = 0;

    while (true) {
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

        if (session.depth == 0) {
            session.bytes_read += read;
        }
        for (read_buffer[0..read]) |byte| {
            // A statement starts at its first non-whitespace byte.
            if (statement_line == 0 and !std.ascii.isWhitespace(byte)) {
                statement_line = line;
            }
            if (byte == '\n') {
                line += 1;
            }

            if (try scanner.feed(session.allocator, byte)) {
                if (!try runStatement(session, scanner, statement_line, stdout, stderr, context, execute)) {
                    return true;
                }
                statement_line = 0;
            } else if (scanner.buffer.items.len == 0) {
                // A client command such as \c cleared the pending input.
                statement_line = 0;
            }
        }
        try session.renderProgress(stderr, false);
    }

    // Input may end without a newline. Supplying one ends a client command, as it does on a line.
    const ended = try scanner.feed(session.allocator, '\n');
    if (ended or scanner.pendingQuery().sql.len != 0) {
        const keep_going = try runStatement(session, scanner, statement_line, stdout, stderr, context, execute);
        return !keep_going;
    }
    return false;
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
    var session = Session.init(allocator, run_options.io, run_options.force);
    session.progress = .{ .total_bytes = run_options.progress_total, .enabled = run_options.show_progress };
    var scanner: Scanner = .{};
    defer scanner.deinit(allocator);
    try scanner.setDelimiter(run_options.delimiter);

    try session.renderProgress(stderr, false);
    _ = try runInput(&session, &scanner, input, stdout, stderr, context, execute);
    try session.renderProgress(stderr, true);
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

/// Feeds `text` through a scanner that uses `delimiter`, and checks the statements it yields.
fn expectStatements(delimiter: []const u8, text: []const u8, expected: []const []const u8) !void {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);
    try scanner.setDelimiter(delimiter);

    var count: usize = 0;
    for (text) |byte| {
        if (try scanner.feed(std.testing.allocator, byte)) {
            try std.testing.expect(count < expected.len);
            try std.testing.expectEqualStrings(expected[count], scanner.pendingQuery().sql);
            count += 1;
            scanner.reset();
        }
    }
    const trailing = scanner.pendingQuery().sql;
    if (trailing.len != 0) {
        try std.testing.expect(count < expected.len);
        try std.testing.expectEqualStrings(expected[count], trailing);
        count += 1;
    }
    try std.testing.expectEqual(expected.len, count);
}

test "default delimiter still ends statements at semicolons" {
    try expectStatements(";", "select 1;select 2;", &.{ "select 1", "select 2" });
}

test "multi-character delimiter ends statements and ignores semicolons" {
    try expectStatements("$$", "create x; select 1$$ select 2$$", &.{ "create x; select 1", "select 2" });
}

test "multi-character delimiter is not seen inside quotes or comments" {
    try expectStatements(
        "$$",
        "select '$$' as a, \"$$\" -- $$\n, `$$` /* $$ */ 1$$",
        &.{"select '$$' as a, \"$$\" -- $$\n, `$$` /* $$ */ 1"},
    );
}

test "a delimiter can end a statement right after a closed quote" {
    try expectStatements("$$", "select 'x$'$$ select 'y'$$", &.{ "select 'x$'", "select 'y'" });
}

test "a delimiter that starts like a comment still ends statements" {
    try expectStatements("//", "select 1 // select /* // */ 2//", &.{ "select 1", "select /* // */ 2" });
}

test "a delimiter command is only recognized at the start of a statement" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    for ("select 1\ndelimiter $$\n") |byte| {
        try std.testing.expect(!try scanner.feed(std.testing.allocator, byte));
    }
    try std.testing.expectEqual(@as(?Command, null), scanner.pendingCommand());
}

test "keywords must end at whitespace, so similar words are plain SQL" {
    try expectStatements(";", "deliminator 1;sourcery 2;", &.{ "deliminator 1", "sourcery 2" });
}

test "scanner reads a delimiter command up to the newline" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    for ("  DELIMITER $$") |byte| {
        try std.testing.expect(!try scanner.feed(std.testing.allocator, byte));
    }
    try std.testing.expect(try scanner.feed(std.testing.allocator, '\n'));
    try std.testing.expectEqual(@as(?Command, .delimiter), scanner.pendingCommand());
    try std.testing.expectEqualStrings("$$", scanner.commandArg());
    try scanner.setDelimiter(scanner.commandArg());
    try std.testing.expectEqualStrings("$$", scanner.delimiter.slice());
}

test "a delimiter command may use a semicolon as its argument" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);
    try scanner.setDelimiter("$$");

    for ("\\d ;") |byte| {
        try std.testing.expect(!try scanner.feed(std.testing.allocator, byte));
    }
    try std.testing.expect(try scanner.feed(std.testing.allocator, '\n'));
    try std.testing.expectEqual(@as(?Command, .delimiter), scanner.pendingCommand());
    try std.testing.expectEqualStrings(";", scanner.commandArg());
}

test "source and \\. take the rest of the line as the file name" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    for ("source   dir/a b.sql  \r") |byte| {
        try std.testing.expect(!try scanner.feed(std.testing.allocator, byte));
    }
    try std.testing.expect(try scanner.feed(std.testing.allocator, '\n'));
    try std.testing.expectEqual(@as(?Command, .source), scanner.pendingCommand());
    try std.testing.expectEqualStrings("dir/a b.sql", scanner.commandArg());
    scanner.reset();

    for ("\\. x.sql\n") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(@as(?Command, .source), scanner.pendingCommand());
    try std.testing.expectEqualStrings("x.sql", scanner.commandArg());
}

test "a backslash clear command at the start of a statement still clears" {
    var scanner: Scanner = .{};
    defer scanner.deinit(std.testing.allocator);

    for ("\\c") |byte| {
        _ = try scanner.feed(std.testing.allocator, byte);
    }
    try std.testing.expectEqualStrings("", scanner.buffer.items);
    try std.testing.expectEqual(Scanner.PromptKind.main, scanner.promptKind());
    try std.testing.expectEqual(@as(?Command, null), scanner.pendingCommand());
}

test "delimiter values are checked and cut to 15 bytes" {
    try std.testing.expectEqualStrings("$$", try checkDelimiter("$$"));
    try std.testing.expectError(error.EmptyDelimiter, checkDelimiter(""));
    try std.testing.expectError(error.BackslashInDelimiter, checkDelimiter("a\\b"));
    try std.testing.expectEqualStrings("abcdefghijklmno", try checkDelimiter("abcdefghijklmnopqrst"));
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

test "batch applies delimiter commands in order" {
    var input = std.Io.Reader.fixed("delimiter $$\nselect 1; select 2$$\ndelimiter ;\nselect 3;\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{}, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualSlices(usize, &.{ 2, 4 }, context.lines.items);
}

test "batch starts with the delimiter it is given" {
    var input = std.Io.Reader.fixed("select 1$$\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{ .delimiter = "$$" }, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqualSlices(usize, &.{1}, context.lines.items);
}

test "a client command at the end of input without a newline still runs" {
    var input = std.Io.Reader.fixed("select 1;\ndelimiter");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{}, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqualSlices(usize, &.{1}, context.lines.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "DELIMITER must be followed by") != null);
}

test "a bad delimiter command is an error that stops the run" {
    var input = std.Io.Reader.fixed("delimiter\nselect 1;\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{}, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqual(@as(usize, 0), context.lines.items.len);
    try std.testing.expectEqualStrings(
        "ERROR: DELIMITER must be followed by a 'delimiter' character or string at line 1\n",
        stderr.buffered(),
    );
}

test "source without an io handle fails with a message" {
    var input = std.Io.Reader.fixed("source x.sql\nselect 1;\n");
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{}, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqual(@as(usize, 0), context.lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "source is not available here at line 1") != null);
}

test "source runs a file with the inherited delimiter and keeps a change it makes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The file is opened relative to the working directory, so use the temp dir's path.
    const inner = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/inner.sql", .{&tmp.sub_path});
    defer std.testing.allocator.free(inner);
    const outer_data = try std.fmt.allocPrint(
        std.testing.allocator,
        "delimiter $$\nselect 1$$\nsource {s}\nselect 3;\n",
        .{inner},
    );
    defer std.testing.allocator.free(outer_data);
    try tmp.dir.writeFile(io, .{ .sub_path = "inner.sql", .data = "select 2$$\ndelimiter ;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outer.sql", .data = outer_data });
    const outer = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/outer.sql", .{&tmp.sub_path});
    defer std.testing.allocator.free(outer);

    const script = try std.fmt.allocPrint(std.testing.allocator, "source {s}\n", .{outer});
    defer std.testing.allocator.free(script);
    var input = std.Io.Reader.fixed(script);
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    var context = RecordingContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const status = try run(std.testing.allocator, &input, &stdout, &stderr, .{ .io = io }, &context, recordQuery);

    try std.testing.expectEqual(@as(u8, 0), status);
    // outer line 2, then inner line 1 (it used $$), then outer line 4 (inner's ";" stayed in effect).
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 4 }, context.lines.items);
}
