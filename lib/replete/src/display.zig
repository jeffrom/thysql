const std = @import("std");
const unicode = @import("unicode.zig");
const highlight = @import("highlight.zig");

const reset_sgr = "\x1b[0m";

/// What to draw besides the plain line. Every field is optional.
pub const Options = struct {
    /// The style of each byte of the buffer, when the line is highlighted.
    styles: ?[]const highlight.Style = null,
    /// The escape sequence for each style.
    theme: highlight.Theme = .{},
    /// Ghost text drawn after the buffer. The caller shows it only with the cursor at the end.
    hint: []const u8 = "",
    /// Text drawn on its own rows below the line.
    diagnostic: []const u8 = "",
};

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

/// Marks where an editable buffer belongs inside a multiline prompt. It uses
/// Readline's invisible delimiters around an otherwise unused control byte so
/// ordinary prompt text is extremely unlikely to contain it accidentally.
pub const prompt_insert_marker = "\x01\x03\x02";

const Builder = struct {
    allocator: std.mem.Allocator,
    columns: usize,
    theme: *const highlight.Theme,
    bytes: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Row) = .empty,
    row_start: usize = 0,
    row: usize = 0,
    col: usize = 0,
    /// The escape sequence of the style that the next visible text takes.
    style: []const u8 = "",
    /// The escape sequence last written to the current row, empty when the row is plain.
    /// Each row starts plain and ends plain, so that a row can be drawn on its own.
    emitted: []const u8 = "",

    fn setStyle(self: *Builder, style: highlight.Style) void {
        self.style = self.theme.sgr(style);
    }

    /// Writes the current style before visible text, unless the row is already in it.
    fn ensureStyle(self: *Builder) !void {
        if (std.mem.eql(u8, self.emitted, self.style)) return;
        if (self.emitted.len > 0) try self.bytes.appendSlice(self.allocator, reset_sgr);
        try self.bytes.appendSlice(self.allocator, self.style);
        self.emitted = self.style;
    }

    /// Returns the current row to plain, so that it ends without a style.
    fn endStyle(self: *Builder) !void {
        if (self.emitted.len == 0) return;
        try self.bytes.appendSlice(self.allocator, reset_sgr);
        self.emitted = "";
    }

    fn finishRow(self: *Builder) !void {
        try self.endStyle();
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
        if (width > 0) try self.ensureStyle();
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
        try self.endStyle();
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

/// Return the length of a Kitty graphics APC command, including its string
/// terminator.
pub fn kittyGraphicsLen(bytes: []const u8) usize {
    if (bytes.len < 4 or !std.mem.startsWith(u8, bytes, "\x1b_G")) return 0;

    var i: usize = 3;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == 0x1b and bytes[i + 1] == '\\') return i + 2;
    }
    return 0;
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
            const graphics_len = kittyGraphicsLen(prompt[i..]);
            if (graphics_len > 0) {
                i += graphics_len;
                continue;
            }
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

const Cursor = struct {
    row: usize,
    col: usize,
};

/// Appends `buffer`, with `styles[i]` for the byte at `i` when given, and leaves the
/// builder plain. Point is the byte whose cursor position is returned.
fn appendBuffer(
    builder: *Builder,
    buffer: []const u8,
    point: usize,
    styles: ?[]const highlight.Style,
) !Cursor {
    var cursor_row: usize = 0;
    var cursor_col: usize = 0;
    var cursor_set = false;
    var i: usize = 0;
    while (i < buffer.len) {
        if (styles) |byte_styles| builder.setStyle(byte_styles[i]);
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
    builder.setStyle(.plain);
    return .{ .row = cursor_row, .col = cursor_col };
}

/// Appends `text` in `style`. The text takes no part in the cursor position.
fn appendStyledText(builder: *Builder, style: highlight.Style, text: []const u8) !void {
    builder.setStyle(style);
    _ = try appendBuffer(builder, text, text.len, null);
}

/// Lays out the prompt and buffer in `columns`, with the cursor at `point`.
pub fn layout(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    buffer: []const u8,
    point: usize,
    columns: usize,
) !Layout {
    return layoutWith(allocator, prompt, buffer, point, columns, .{});
}

/// Like `layout`, with the styles, hint and diagnostic in `options`. The hint follows the
/// buffer on its row, and the diagnostic goes on the rows after the whole prompt.
pub fn layoutWith(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    buffer: []const u8,
    point: usize,
    columns: usize,
    options: Options,
) !Layout {
    std.debug.assert(point <= buffer.len);
    if (options.styles) |styles| std.debug.assert(styles.len == buffer.len);
    var builder: Builder = .{
        .allocator = allocator,
        .columns = @max(columns, 1),
        .theme = &options.theme,
    };
    errdefer builder.bytes.deinit(allocator);
    errdefer builder.rows.deinit(allocator);

    const cursor = if (std.mem.indexOf(u8, prompt, prompt_insert_marker)) |insert_at| blk: {
        try appendPrompt(&builder, prompt[0..insert_at]);
        const result = try appendBuffer(&builder, buffer, point, options.styles);
        if (options.hint.len > 0) try appendStyledText(&builder, .hint, options.hint);
        try appendPrompt(&builder, prompt[insert_at + prompt_insert_marker.len ..]);
        break :blk result;
    } else blk: {
        try appendPrompt(&builder, prompt);
        const result = try appendBuffer(&builder, buffer, point, options.styles);
        if (options.hint.len > 0) try appendStyledText(&builder, .hint, options.hint);
        break :blk result;
    };

    if (options.diagnostic.len > 0) {
        try builder.hardBreak();
        try appendStyledText(&builder, .diagnostic, options.diagnostic);
    }
    return builder.finish(cursor.row, cursor.col);
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

test "buffer can be inserted before rows beneath a multiline prompt" {
    var result = try layout(
        std.testing.allocator,
        "top\nmid> " ++ prompt_insert_marker ++ "\nbottom",
        "ok",
        2,
        80,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.rows.items.len);
    try std.testing.expectEqualStrings("top", result.row(0));
    try std.testing.expectEqualStrings("mid> ok", result.row(1));
    try std.testing.expectEqualStrings("bottom", result.row(2));
    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 7), result.cursor_col);
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

test "a coloured connection tag keeps the cursor column" {
    // The tag "[main/ro]" and " app> " are 15 columns; the colour codes add none.
    var result = try layout(std.testing.allocator, "\x1b[31m[main/ro]\x1b[0m app> ", "", 0, 80);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\x1b[31m[main/ro]\x1b[0m app> ", result.row(0));
    try std.testing.expectEqual(@as(usize, 0), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 15), result.cursor_col);
}

test "kitty graphics setup is not included in repaintable rows" {
    var result = try layout(
        std.testing.allocator,
        "\x01\x1b_Ga=p,U=1,i=42,c=2,r=2,q=2\x1b\\\x02" ++
            "\x1b[38;5;42m\u{10eeee}\u{0305}\u{10eeee}\x1b[39m\n" ++
            "\x1b[38;5;42m\u{10eeee}\u{030d}\u{10eeee}\x1b[39m > ",
        "ok",
        2,
        20,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "\x1b[38;5;42m\u{10eeee}\u{0305}\u{10eeee}\x1b[39m",
        result.row(0),
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;42m\u{10eeee}\u{030d}\u{10eeee}\x1b[39m > ok",
        result.row(1),
    );
    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 7), result.cursor_col);
}

test "styled text re-emits its style on each wrapped row" {
    var result = try layoutWith(std.testing.allocator, "", "abcdef", 6, 4, .{
        .styles = &.{ .keyword, .keyword, .keyword, .keyword, .keyword, .keyword },
        .theme = .{ .keyword = "<k>" },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);
    try std.testing.expectEqualStrings("<k>abcd\x1b[0m", result.row(0));
    try std.testing.expectEqualStrings("<k>ef\x1b[0m", result.row(1));
    try std.testing.expectEqual(@as(usize, 1), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 2), result.cursor_col);
}

test "styles and escape sequences do not change the cursor column" {
    const styles = [_]highlight.Style{ .keyword, .keyword, .keyword, .keyword, .keyword, .keyword, .plain, .identifier };
    var result = try layoutWith(std.testing.allocator, "> ", "select x", 6, 80, .{
        .styles = &styles,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.cursor_row);
    try std.testing.expectEqual(@as(usize, 8), result.cursor_col);
}

test "hint follows the buffer in the hint style without moving the cursor" {
    var result = try layoutWith(std.testing.allocator, "> ", "sel", 3, 80, .{
        .hint = "ect *",
        .theme = .{ .hint = "<h>" },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("> sel<h>ect *\x1b[0m", result.row(0));
    try std.testing.expectEqual(@as(usize, 5), result.cursor_col);
}

test "diagnostic gets its own row below the line" {
    var result = try layoutWith(std.testing.allocator, "> ", "x y", 3, 80, .{
        .diagnostic = "syntax error",
        .theme = .{ .diagnostic = "<d>" },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.rows.items.len);
    try std.testing.expectEqualStrings("> x y", result.row(0));
    try std.testing.expectEqualStrings("<d>syntax error\x1b[0m", result.row(1));
    try std.testing.expectEqual(@as(usize, 0), result.cursor_row);
}
