const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Query = struct {
    sql: []const u8,
    vertical: bool,
};

pub const QueryResult = struct {
    success: bool = true,
    rows_affected: u64 = 0,
    elapsed_ns: u64 = 0,
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

fn stdinProgressTotal(stdin: std.Io.File, io: std.Io) ?u64 {
    const stat = stdin.stat(io) catch return null;
    if (stat.kind != .file or stat.size == 0) {
        return null;
    }
    return stat.size;
}

const Progress = struct {
    total_bytes: ?u64,
    last_width: usize = 0,

    const bar_width = 30;

    fn render(self: *Progress, stderr: *std.Io.Writer, bytes_read: u64, query_count: u64, final: bool) !void {
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

const Summary = struct {
    query_count: u64 = 0,
    rows_affected: u64 = 0,
    timings: std.ArrayList(u64) = .empty,
    started_at: std.Io.Clock.Timestamp,

    const histogram_width = 30;

    fn deinit(self: *Summary, allocator: Allocator) void {
        self.timings.deinit(allocator);
    }

    fn record(self: *Summary, allocator: Allocator, result: QueryResult) !void {
        self.query_count += 1;
        self.rows_affected += result.rows_affected;
        try self.timings.append(allocator, result.elapsed_ns);
    }

    fn render(self: *Summary, stderr: *std.Io.Writer, io: std.Io) !void {
        const total_ns: u64 = @intCast(self.started_at.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
        try stderr.print("Batch summary\n", .{});
        try stderr.print("  Queries: {}\n", .{self.query_count});
        try stderr.print("  Rows affected: {}\n", .{self.rows_affected});
        try stderr.print("  Total time: ", .{});
        try renderDuration(stderr, total_ns);
        try stderr.print("\n", .{});

        if (self.timings.items.len == 0) {
            try stderr.flush();
            return;
        }

        std.mem.sort(u64, self.timings.items, {}, comptime std.sort.asc(u64));

        var sum: u128 = 0;
        for (self.timings.items) |timing| {
            sum += timing;
        }

        const average: u64 = @intCast(@divTrunc(sum, self.timings.items.len));
        const p95 = percentile(self.timings.items, 95);
        const p99 = percentile(self.timings.items, 99);
        const max = self.timings.items[self.timings.items.len - 1];

        try stderr.print("  Query timings:\n", .{});
        try renderTimingBar(stderr, "avg", average, max);
        try renderTimingBar(stderr, "p95", p95, max);
        try renderTimingBar(stderr, "p99", p99, max);
        try renderTimingBar(stderr, "max", max, max);
        try stderr.flush();
    }

    fn percentile(sorted_timings: []const u64, comptime percentile_value: u64) u64 {
        std.debug.assert(sorted_timings.len > 0);
        const numerator = percentile_value * sorted_timings.len;
        const index = @min(sorted_timings.len - 1, @divTrunc(numerator + 99, 100) - 1);
        return sorted_timings[index];
    }

    fn renderTimingBar(stderr: *std.Io.Writer, label: []const u8, value: u64, max: u64) !void {
        const filled = if (max == 0)
            0
        else
            @max(@as(usize, 1), @min(histogram_width, @as(usize, @intCast(@divTrunc(@as(u128, value) * histogram_width, max)))));

        try stderr.print("    {s: >3} [", .{label});
        for (0..histogram_width) |i| {
            const char: u8 = if (i < filled) '=' else ' ';
            try stderr.print("{c}", .{char});
        }
        try stderr.print("] ", .{});
        try renderDuration(stderr, value);
        try stderr.print("\n", .{});
    }

    fn renderDuration(stderr: *std.Io.Writer, ns: u64) !void {
        if (ns < std.time.ns_per_s) {
            const rounded_us = @divTrunc(ns + 500, std.time.ns_per_us);
            const millis = @divTrunc(rounded_us, 1000);
            const micros = @rem(rounded_us, 1000);
            try stderr.print("{}.", .{millis});
            if (micros < 100) {
                try stderr.print("0", .{});
            }
            if (micros < 10) {
                try stderr.print("0", .{});
            }
            try stderr.print("{} ms", .{micros});
            return;
        }

        const rounded_ms = @divTrunc(ns + std.time.ns_per_ms / 2, std.time.ns_per_ms);
        const seconds = @divTrunc(rounded_ms, 1000);
        const millis = @rem(rounded_ms, 1000);
        try stderr.print("{}.", .{seconds});
        if (millis < 100) {
            try stderr.print("0", .{});
        }
        if (millis < 10) {
            try stderr.print("0", .{});
        }
        try stderr.print("{} s", .{millis});
    }
};

fn executeStatement(
    allocator: Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    scanner: *Scanner,
    bytes_read: u64,
    progress: *Progress,
    summary: *Summary,
    context: anytype,
    comptime execute: fn (@TypeOf(context), std.Io, *std.Io.Writer, Query) anyerror!QueryResult,
) !bool {
    const query = scanner.pendingQuery();
    defer scanner.reset();
    if (query.sql.len == 0) {
        return true;
    }

    const result = try execute(context, io, stdout, query);
    if (!result.success) {
        return false;
    }
    try summary.record(allocator, result);
    try progress.render(stderr, bytes_read, summary.query_count, false);
    return true;
}

pub fn run(
    allocator: Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), std.Io, *std.Io.Writer, Query) anyerror!QueryResult,
) !u8 {
    var progress = Progress{ .total_bytes = stdinProgressTotal(stdin, io) };
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    var read_buffer: [8192]u8 = undefined;
    var scanner: Scanner = .{};
    defer scanner.deinit(allocator);

    var bytes_read: u64 = 0;
    var summary = Summary{ .started_at = std.Io.Clock.Timestamp.now(io, .awake) };
    defer summary.deinit(allocator);
    try progress.render(stderr, bytes_read, summary.query_count, false);

    while (true) {
        const read = try stdin_reader.interface.readSliceShort(&read_buffer);
        if (read == 0) {
            break;
        }

        bytes_read += read;
        for (read_buffer[0..read]) |byte| {
            if (try scanner.feed(allocator, byte)) {
                if (!try executeStatement(allocator, io, stdout, stderr, &scanner, bytes_read, &progress, &summary, context, execute)) {
                    try progress.render(stderr, bytes_read, summary.query_count, true);
                    try summary.render(stderr, io);
                    return 1;
                }
            }
        }
        try progress.render(stderr, bytes_read, summary.query_count, false);
    }

    const trailing_query = scanner.pendingQuery();
    if (trailing_query.sql.len != 0) {
        if (!try executeStatement(allocator, io, stdout, stderr, &scanner, bytes_read, &progress, &summary, context, execute)) {
            try progress.render(stderr, bytes_read, summary.query_count, true);
            try summary.render(stderr, io);
            return 1;
        }
    }

    try progress.render(stderr, bytes_read, summary.query_count, true);
    try summary.render(stderr, io);
    return 0;
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
