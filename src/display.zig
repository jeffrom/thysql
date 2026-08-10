const std = @import("std");
const unicode = @import("unicode.zig");

pub const Row = struct {
    start: usize,
    end: usize,
};

pub const Layout = struct {
    bytes: std.ArrayList(u8),
    rows: std.ArrayList(Row),
    cursor_row: usize,
    cursor_col: usize,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.rows.deinit(allocator);
    }

    pub fn row(self: *const Layout, index: usize) []const u8 {
        const bounds = self.rows.items[index];
        return self.bytes.items[bounds.start..bounds.end];
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    columns: usize,
    bytes: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Row) = .empty,
    row_start: usize = 0,
    row: usize = 0,
    col: usize = 0,

    fn finishRow(self: *Builder) !void {
        try self.rows.append(self.allocator, .{
            .start = self.row_start,
            .end = self.bytes.items.len,
        });
        self.row += 1;
        self.col = 0;
        self.row_start = self.bytes.items.len;
    }

    fn appendRaw(self: *Builder, bytes: []const u8, width: usize) !void {
        if (width > 0 and self.col > 0 and self.col + width > self.columns) {
            try self.finishRow();
        }
        try self.bytes.appendSlice(self.allocator, bytes);
        self.col += width;
        if (self.col >= self.columns) try self.finishRow();
    }

    fn hardBreak(self: *Builder) !void {
        try self.finishRow();
    }

    fn finish(self: *Builder, cursor_row: usize, cursor_col: usize) !Layout {
        // A character in the final terminal column creates a real, empty next
        // screen row. finishRow has already added the full row in that case.
        try self.rows.append(self.allocator, .{
            .start = self.row_start,
            .end = self.bytes.items.len,
        });
        return .{
            .bytes = self.bytes,
            .rows = self.rows,
            .cursor_row = cursor_row,
            .cursor_col = cursor_col,
        };
    }
};

fn ansiCsiLen(bytes: []const u8) usize {
    if (bytes.len < 2 or bytes[0] != 0x1b or bytes[1] != '[') return 0;
    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
    if (i == bytes.len or bytes[i] < 0x40 or bytes[i] > 0x7e) return 0;
    return i + 1;
}

fn appendPrompt(builder: *Builder, prompt: []const u8) !void {
    var i: usize = 0;
    var invisible = false;
    while (i < prompt.len) {
        if (prompt[i] == 0x01) {
            invisible = true;
            i += 1;
            continue;
        }
        if (prompt[i] == 0x02) {
            invisible = false;
            i += 1;
            continue;
        }
        if (prompt[i] == '\n') {
            try builder.hardBreak();
            i += 1;
            continue;
        }
        if (prompt[i] == '\r' and i + 1 < prompt.len and prompt[i + 1] == '\n') {
            i += 1;
            continue;
        }
        if (prompt[i] == 0x1b) {
            const len = ansiCsiLen(prompt[i..]);
            if (len > 0) {
                try builder.appendRaw(prompt[i .. i + len], 0);
                i += len;
                continue;
            }
        }

        const len = unicode.codepointLenAt(prompt, i);
        const width = if (invisible) 0 else unicode.displayWidth(prompt[i .. i + len]);
        try builder.appendRaw(prompt[i .. i + len], width);
        i += len;
    }
}

pub fn layout(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    buffer: []const u8,
    point: usize,
    columns: usize,
) !Layout {
    std.debug.assert(point <= buffer.len);
    var builder: Builder = .{
        .allocator = allocator,
        .columns = @max(columns, 1),
    };
    errdefer builder.bytes.deinit(allocator);
    errdefer builder.rows.deinit(allocator);

    try appendPrompt(&builder, prompt);

    var cursor_row: usize = 0;
    var cursor_col: usize = 0;
    var cursor_set = false;
    var i: usize = 0;
    while (i < buffer.len) {
        // Readline never splits a multicolumn character across the right
        // margin. Point immediately before that character belongs to the row
        // where the character will actually be drawn.
        if (buffer[i] >= 0x20 and buffer[i] != 0x7f) {
            const len = unicode.codepointLenAt(buffer, i);
            const width = unicode.displayWidth(buffer[i .. i + len]);
            if (width > 1 and builder.col > 0 and builder.col + width > builder.columns) {
                try builder.finishRow();
            }
        }
        if (i == point) {
            cursor_row = builder.row;
            cursor_col = builder.col;
            cursor_set = true;
        }

        const byte = buffer[i];
        if (byte == '\n') {
            try builder.hardBreak();
            i += 1;
            continue;
        }
        if (byte == '\t') {
            const width = 8 - (builder.col % 8);
            for (0..width) |_| try builder.appendRaw(" ", 1);
            i += 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            const shown: [2]u8 = .{ '^', if (byte == 0x7f) '?' else byte + 0x40 };
            try builder.appendRaw(shown[0..1], 1);
            try builder.appendRaw(shown[1..2], 1);
            i += 1;
            continue;
        }

        const len = unicode.codepointLenAt(buffer, i);
        const width = unicode.displayWidth(buffer[i .. i + len]);
        try builder.appendRaw(buffer[i .. i + len], width);
        i += len;
    }

    if (!cursor_set) {
        cursor_row = builder.row;
        cursor_col = builder.col;
    }
    return builder.finish(cursor_row, cursor_col);
}

test "layout wraps and tracks the cursor" {
    var result = try layout(std.testing.allocator, "> ", "abcdefgh", 5, 6);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);
    try std.testing.expectEqualStrings("> abcd", result.row(0));
    try std.testing.expectEqualStrings("efgh", result.row(1));
    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 1), result.cursor_col);
}

test "layout honors hard newlines without repeating the prompt" {
    var result = try layout(std.testing.allocator, "> ", "first\nsecond", 6, 80);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);
    try std.testing.expectEqualStrings("> first", result.row(0));
    try std.testing.expectEqualStrings("second", result.row(1));
    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), result.cursor_col);
}

test "layout moves a wide character to the next row" {
    var result = try layout(std.testing.allocator, "", "abc界", 6, 4);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc", result.row(0));
    try std.testing.expectEqualStrings("界", result.row(1));
    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), result.cursor_col);
}

test "point before a wrapped wide character follows it to the next row" {
    var result = try layout(std.testing.allocator, "", "abc界", 3, 4);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 0), result.cursor_col);
}

test "tabs and displayed control characters can wrap" {
    var result = try layout(std.testing.allocator, "", "\t\x03", 2, 4);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.items.len);
    try std.testing.expectEqualStrings("    ", result.row(0));
    try std.testing.expectEqualStrings("    ", result.row(1));
    try std.testing.expectEqualStrings("^C", result.row(2));
}

test "multiline prompts and readline ignore markers have zero display width" {
    var result = try layout(
        std.testing.allocator,
        "title\n\x01\x1b[32m\x02> \x01\x1b[0m\x02",
        "ok",
        2,
        20,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("title", result.row(0));
    try std.testing.expectEqualStrings("\x1b[32m> \x1b[0mok", result.row(1));
    try std.testing.expectEqual(@as(usize, 4), result.cursor_col);
}
