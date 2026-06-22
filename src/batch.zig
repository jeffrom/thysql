const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Query = struct {
    sql: []const u8,
    vertical: bool,
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
    const State = enum {
        normal,
        maybe_dash_comment,
        maybe_block_comment,
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
            else => {},
        }
        try self.buffer.append(allocator, byte);
        return false;
    }

    pub fn pendingQuery(self: *Scanner) Query {
        return parseQueryInput(self.buffer.items);
    }

    pub fn reset(self: *Scanner) void {
        self.buffer.clearRetainingCapacity();
        self.state = .normal;
        self.escaped = false;
        self.block_comment_star = false;
    }
};

fn stdinProgressTotal(stdin: std.Io.File, io: std.Io) ?u64 {
    const stat = stdin.stat(io) catch return null;
    if (stat.kind != .file or stat.size == 0) {
        return null;
    }
    return stat.size;
}

fn renderProgress(stderr: *std.Io.Writer, bytes_read: u64, total_bytes: ?u64, query_count: u64, final: bool) !void {
    if (total_bytes) |total| {
        const percent = @divTrunc(bytes_read * 100, total);
        try stderr.print("\rProcessed {}/{} bytes ({}%), {} quer{s}", .{
            bytes_read,
            total,
            percent,
            query_count,
            if (query_count == 1) "y" else "ies",
        });
    } else {
        try stderr.print("\r{} quer{s}", .{
            query_count,
            if (query_count == 1) "y" else "ies",
        });
    }
    if (final) {
        try stderr.print("\n", .{});
    }
    try stderr.flush();
}

fn executeStatement(
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    scanner: *Scanner,
    bytes_read: u64,
    total_bytes: ?u64,
    query_count: *u64,
    context: anytype,
    comptime execute: fn (@TypeOf(context), std.Io, *std.Io.Writer, Query) anyerror!bool,
) !bool {
    const query = scanner.pendingQuery();
    defer scanner.reset();
    if (query.sql.len == 0) {
        return true;
    }

    if (!try execute(context, io, stdout, query)) {
        return false;
    }
    query_count.* += 1;
    try renderProgress(stderr, bytes_read, total_bytes, query_count.*, false);
    return true;
}

pub fn run(
    allocator: Allocator,
    io: std.Io,
    stdin: std.Io.File,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    context: anytype,
    comptime execute: fn (@TypeOf(context), std.Io, *std.Io.Writer, Query) anyerror!bool,
) !u8 {
    const total_bytes = stdinProgressTotal(stdin, io);
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    var read_buffer: [8192]u8 = undefined;
    var scanner: Scanner = .{};
    defer scanner.deinit(allocator);

    var bytes_read: u64 = 0;
    var query_count: u64 = 0;
    try renderProgress(stderr, bytes_read, total_bytes, query_count, false);

    while (true) {
        const read = try stdin_reader.interface.readSliceShort(&read_buffer);
        if (read == 0) {
            break;
        }

        bytes_read += read;
        for (read_buffer[0..read]) |byte| {
            if (try scanner.feed(allocator, byte)) {
                if (!try executeStatement(io, stdout, stderr, &scanner, bytes_read, total_bytes, &query_count, context, execute)) {
                    try renderProgress(stderr, bytes_read, total_bytes, query_count, true);
                    return 1;
                }
            }
        }
        try renderProgress(stderr, bytes_read, total_bytes, query_count, false);
    }

    const trailing_query = scanner.pendingQuery();
    if (trailing_query.sql.len != 0) {
        if (!try executeStatement(io, stdout, stderr, &scanner, bytes_read, total_bytes, &query_count, context, execute)) {
            try renderProgress(stderr, bytes_read, total_bytes, query_count, true);
            return 1;
        }
    }

    try renderProgress(stderr, bytes_read, total_bytes, query_count, true);
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
