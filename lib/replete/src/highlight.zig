//! Syntax highlighting: the styles a line's bytes can take, the escape sequences
//! they are drawn with, and how a highlighter's spans become one style per byte.

const std = @import("std");

/// A style for part of the line, or for text that replete draws itself.
pub const Style = enum {
    /// No styling. Text in this style has no escape sequences.
    plain,
    /// A reserved SQL keyword.
    keyword,
    /// A keyword that may also be an identifier, such as `ACCOUNT`.
    keyword_nonreserved,
    identifier,
    quoted_identifier,
    string,
    number,
    comment,
    operator,
    variable,
    function,
    /// The statement delimiter, such as `;`.
    delimiter,
    /// A client command such as `\G` or `DELIMITER`.
    client_command,
    /// A syntax error. Drawn as an underline, curly when `Theme.undercurl` is set.
    @"error",
    /// The ghost text that a `Hinter` suggests after the cursor.
    hint,
    /// The message from a `Diagnoser`, shown below the line.
    diagnostic,
};

/// A run of bytes in a line, styled by a highlighter. `start` and `len` are byte offsets.
pub const Span = struct {
    start: usize,
    len: usize,
    style: Style,
};

/// The escape sequences for each style. The defaults are mid-tone colors that read on
/// both dark and light backgrounds. Every field is an SGR sequence, or empty for none.
pub const Theme = struct {
    keyword: []const u8 = "\x1b[1;38;5;32m",
    keyword_nonreserved: []const u8 = "\x1b[38;5;32m",
    identifier: []const u8 = "",
    quoted_identifier: []const u8 = "\x1b[38;5;66m",
    string: []const u8 = "\x1b[38;5;28m",
    number: []const u8 = "\x1b[38;5;166m",
    comment: []const u8 = "\x1b[2;38;5;244m",
    operator: []const u8 = "\x1b[38;5;241m",
    variable: []const u8 = "\x1b[38;5;97m",
    function: []const u8 = "\x1b[38;5;31m",
    delimiter: []const u8 = "\x1b[1m",
    client_command: []const u8 = "\x1b[38;5;125m",
    @"error": []const u8 = "\x1b[4:3m",
    /// The error style when `undercurl` is false: a straight underline. A theme that colours
    /// errors sets this too, so the colour holds without curly underlines.
    error_straight: []const u8 = "\x1b[4m",
    hint: []const u8 = "\x1b[2m",
    diagnostic: []const u8 = "\x1b[38;5;160m",
    /// Whether errors use a curly underline. Terminals without curly underlines
    /// show a straight one when this is false.
    undercurl: bool = true,

    /// The escape sequence that starts `style`. `plain` gives the empty string.
    pub fn sgr(self: *const Theme, style: Style) []const u8 {
        return switch (style) {
            .plain => "",
            .keyword => self.keyword,
            .keyword_nonreserved => self.keyword_nonreserved,
            .identifier => self.identifier,
            .quoted_identifier => self.quoted_identifier,
            .string => self.string,
            .number => self.number,
            .comment => self.comment,
            .operator => self.operator,
            .variable => self.variable,
            .function => self.function,
            .delimiter => self.delimiter,
            .client_command => self.client_command,
            .@"error" => if (self.undercurl) self.@"error" else self.error_straight,
            .hint => self.hint,
            .diagnostic => self.diagnostic,
        };
    }
};

/// Gives each byte of a line of `len` bytes the style of the span that covers it.
/// Spans may overlap or come in any order: where they overlap, the later span wins.
/// Bytes that no span covers, and the parts of spans past the end of the line, are plain.
/// The caller frees the result with `allocator`.
pub fn styleBytes(allocator: std.mem.Allocator, len: usize, spans: []const Span) std.mem.Allocator.Error![]Style {
    const styles = try allocator.alloc(Style, len);
    @memset(styles, .plain);
    for (spans) |span| {
        const start = @min(span.start, len);
        const end = @min(span.start +| span.len, len);
        @memset(styles[start..end], span.style);
    }
    return styles;
}

test "plain style has no escape sequence" {
    const theme: Theme = .{};
    try std.testing.expectEqualStrings("", theme.sgr(.plain));
    try std.testing.expectEqualStrings("", theme.sgr(.identifier));
}

test "SQL token styles have their own escape sequences unless the theme leaves them plain" {
    var theme: Theme = .{};
    try std.testing.expect(theme.sgr(.keyword_nonreserved).len > 0);
    try std.testing.expect(!std.mem.eql(u8, theme.sgr(.keyword), theme.sgr(.keyword_nonreserved)));
    try std.testing.expect(theme.sgr(.quoted_identifier).len > 0);
    try std.testing.expect(theme.sgr(.delimiter).len > 0);
    try std.testing.expect(theme.sgr(.client_command).len > 0);

    theme.quoted_identifier = "";
    try std.testing.expectEqualStrings("", theme.sgr(.quoted_identifier));
}

test "error style is a curly underline unless the theme turns it off" {
    var theme: Theme = .{};
    try std.testing.expectEqualStrings("\x1b[4:3m", theme.sgr(.@"error"));

    theme.undercurl = false;
    try std.testing.expectEqualStrings("\x1b[4m", theme.sgr(.@"error"));

    theme.error_straight = "\x1b[4m\x1b[58:2::1:2:3m";
    try std.testing.expectEqualStrings("\x1b[4m\x1b[58:2::1:2:3m", theme.sgr(.@"error"));
}

test "styles cover their spans and leave other bytes plain" {
    const allocator = std.testing.allocator;
    const styles = try styleBytes(allocator, 10, &.{
        .{ .start = 2, .len = 3, .style = .keyword },
        .{ .start = 7, .len = 1, .style = .string },
    });
    defer allocator.free(styles);

    try std.testing.expectEqualSlices(Style, &.{
        .plain, .plain, .keyword, .keyword, .keyword, .plain, .plain, .string, .plain, .plain,
    }, styles);
}

test "overlapping spans take the later span where they meet" {
    const allocator = std.testing.allocator;
    const styles = try styleBytes(allocator, 6, &.{
        .{ .start = 0, .len = 4, .style = .identifier },
        .{ .start = 2, .len = 3, .style = .number },
    });
    defer allocator.free(styles);

    try std.testing.expectEqualSlices(Style, &.{
        .identifier, .identifier, .number, .number, .number, .plain,
    }, styles);
}

test "spans past the end of the line are clipped" {
    const allocator = std.testing.allocator;
    const styles = try styleBytes(allocator, 3, &.{
        .{ .start = 2, .len = 10, .style = .comment },
        .{ .start = 9, .len = 4, .style = .string },
    });
    defer allocator.free(styles);

    try std.testing.expectEqualSlices(Style, &.{ .plain, .plain, .comment }, styles);
}
