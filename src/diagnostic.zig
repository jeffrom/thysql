//! Diagnostics drawn as rustc draws them: the lines of the statement that an error is about, with
//! labelled underlines that relate places to each other, and notes below.
//!
//! ```
//!   --> query:1:8
//!    |
//!  1 | SELECT id FROM users u JOIN orders o ON o.user_id = u.id
//!    |        ^^      -------      -------- `orders` has a column `id`
//!    |        |       |
//!    |        |       `users` has a column `id`
//!    |        ambiguous
//!    |
//!    = help: qualify it: `u.id` or `o.id`
//! ```
//!
//! A primary label (`^`) marks the error itself, and secondary labels (`-`) the places it relates
//! to. Lines without labels are left out, as `...`, except a single line between two labelled ones.
//! A label that runs over several lines is drawn on its first line, to the end of that line.

const std = @import("std");
const Writer = std.Io.Writer;
const unicode = @import("unicode.zig");

pub const Severity = enum {
    @"error",
    warning,

    fn name(self: Severity) []const u8 {
        return @tagName(self);
    }
};

pub const Label = struct {
    /// Byte offsets into the source, end exclusive. An empty span marks the place before `start`.
    start: usize,
    end: usize,
    message: []const u8 = "",
    primary: bool = false,
};

pub const Note = struct {
    pub const Kind = enum { note, help };
    kind: Kind,
    text: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity = .@"error",
    /// Such as "1052". Shown in the header.
    code: ?[]const u8 = null,
    /// The header's message. `renderSnippet` does not show it.
    message: []const u8 = "",
    labels: []const Label = &.{},
    notes: []const Note = &.{},
};

pub const Style = struct {
    color: bool = false,

    const reset = "\x1b[0m";
    const gutter = "\x1b[1;34m";
    const secondary = "\x1b[1;34m";
    const bold = "\x1b[1m";

    fn primary(severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => "\x1b[1;31m",
            .warning => "\x1b[1;33m",
        };
    }

    fn begin(self: Style, out: *Writer, sgr: []const u8) Writer.Error!void {
        if (self.color) try out.writeAll(sgr);
    }

    fn end(self: Style, out: *Writer) Writer.Error!void {
        if (self.color) try out.writeAll(reset);
    }
};

/// Writes the header, `error[1052]: message`, then the snippet.
pub fn render(out: *Writer, source: []const u8, origin: []const u8, diagnostic: Diagnostic, style: Style) Writer.Error!void {
    try style.begin(out, Style.primary(diagnostic.severity));
    try out.writeAll(diagnostic.severity.name());
    if (diagnostic.code) |code| try out.print("[{s}]", .{code});
    try style.end(out);
    try style.begin(out, Style.bold);
    try out.print(": {s}", .{diagnostic.message});
    try style.end(out);
    try out.writeByte('\n');
    try renderSnippet(out, source, origin, diagnostic, style);
}

/// The most labels drawn on one line. Later ones on the line are left out.
const max_labels_per_line = 16;

/// Writes the labelled lines of `source` and the notes, without a header. `origin` names the
/// source in the location line, ` --> origin:line:column`.
pub fn renderSnippet(out: *Writer, source: []const u8, origin: []const u8, diagnostic: Diagnostic, style: Style) Writer.Error!void {
    const labels = diagnostic.labels;

    // The lines that have labels, in order, without repeats.
    var lines_buffer: [64]usize = undefined;
    var line_count: usize = 0;
    for (labels) |label| {
        const line = lineOf(source, @min(label.start, source.len));
        if (std.mem.indexOfScalar(usize, lines_buffer[0..line_count], line) != null) continue;
        if (line_count == lines_buffer.len) break;
        lines_buffer[line_count] = line;
        line_count += 1;
    }
    const lines = lines_buffer[0..line_count];
    std.mem.sort(usize, lines, {}, std.sort.asc(usize));

    var max_line: usize = 1;
    for (lines) |line| max_line = @max(max_line, line + 1);
    const width = digits(max_line);

    // The location of the primary label, or of the first one.
    if (labels.len > 0) {
        var main = labels[0];
        for (labels) |label| {
            if (label.primary) {
                main = label;
                break;
            }
        }
        const at = @min(main.start, source.len);
        const line = lineOf(source, at);
        const column = displayColumn(source[lineStart(source, at)..at]) + 1;
        try out.splatByteAll(' ', width);
        try style.begin(out, Style.gutter);
        try out.writeAll("--> ");
        try style.end(out);
        try out.print("{s}:{d}:{d}\n", .{ origin, line + 1, column });
        try emptyGutter(out, width, style);
    }

    var previous: ?usize = null;
    for (lines) |line| {
        if (previous) |p| {
            if (line == p + 2) {
                try sourceLine(out, source, p + 1, width, style);
            } else if (line > p + 2) {
                try style.begin(out, Style.gutter);
                try out.writeAll("...");
                try style.end(out);
                try out.writeByte('\n');
            }
        }
        try sourceLine(out, source, line, width, style);
        try labelRows(out, source, line, labels, width, diagnostic.severity, style);
        previous = line;
    }

    if (diagnostic.notes.len > 0) {
        if (labels.len > 0) try emptyGutter(out, width, style);
        for (diagnostic.notes) |note| {
            try out.splatByteAll(' ', width + 1);
            try style.begin(out, Style.gutter);
            try out.writeByte('=');
            try style.end(out);
            try out.writeByte(' ');
            try style.begin(out, Style.bold);
            try out.writeAll(@tagName(note.kind));
            try style.end(out);
            try out.print(": {s}\n", .{note.text});
        }
    }
}

fn emptyGutter(out: *Writer, width: usize, style: Style) Writer.Error!void {
    try out.splatByteAll(' ', width + 1);
    try style.begin(out, Style.gutter);
    try out.writeByte('|');
    try style.end(out);
    try out.writeByte('\n');
}

/// Writes ` 12 | text` for the 0-based `line`.
fn sourceLine(out: *Writer, source: []const u8, line: usize, width: usize, style: Style) Writer.Error!void {
    const range = lineRange(source, line);
    try style.begin(out, Style.gutter);
    try out.splatByteAll(' ', width - digits(line + 1));
    try out.print("{d} |", .{line + 1});
    try style.end(out);
    const text = std.mem.trimEnd(u8, source[range.start..range.end], "\r");
    if (text.len > 0) try out.writeByte(' ');
    for (text) |byte| {
        if (byte == '\t') try out.splatByteAll(' ', tab_width) else try out.writeByte(byte);
    }
    try out.writeByte('\n');
}

const Mark = enum(u8) { none, primary, secondary };

/// One row under a source line: a mark per display column, and text after them.
const Row = struct {
    cells: [max_columns]u8 = undefined,
    marks: [max_columns]Mark = undefined,
    len: usize = 0,

    const max_columns = 512;

    fn set(self: *Row, column: usize, byte: u8, mark: Mark) void {
        if (column >= max_columns) return;
        while (self.len <= column) : (self.len += 1) {
            self.cells[self.len] = ' ';
            self.marks[self.len] = .none;
        }
        self.cells[column] = byte;
        self.marks[column] = mark;
    }

    fn write(self: *const Row, out: *Writer, width: usize, severity: Severity, style: Style, message: ?struct { text: []const u8, mark: Mark, gap: bool = true }) Writer.Error!void {
        try out.splatByteAll(' ', width + 1);
        try style.begin(out, Style.gutter);
        try out.writeByte('|');
        try style.end(out);
        if (self.len > 0 or message != null) try out.writeByte(' ');
        var current: Mark = .none;
        for (self.cells[0..self.len], self.marks[0..self.len]) |byte, mark| {
            if (mark != current) {
                if (current != .none) try style.end(out);
                if (mark != .none) try style.begin(out, sgrOf(mark, severity));
                current = mark;
            }
            try out.writeByte(byte);
        }
        if (current != .none) try style.end(out);
        if (message) |m| {
            if (self.len > 0 and m.gap) try out.writeByte(' ');
            try style.begin(out, sgrOf(m.mark, severity));
            try out.writeAll(m.text);
            try style.end(out);
        }
        try out.writeByte('\n');
    }
};

fn sgrOf(mark: Mark, severity: Severity) []const u8 {
    return switch (mark) {
        .primary => Style.primary(severity),
        .secondary, .none => Style.secondary,
    };
}

const Placed = struct {
    column: usize,
    width: usize,
    label: Label,

    fn mark(self: Placed) Mark {
        return if (self.label.primary) .primary else .secondary;
    }
};

/// Writes the underlines of the labels on `line`, then their messages: the rightmost one after its
/// underline, and the others below, each on a line of its own, joined to its underline by `|`.
fn labelRows(out: *Writer, source: []const u8, line: usize, labels: []const Label, width: usize, severity: Severity, style: Style) Writer.Error!void {
    const range = lineRange(source, line);
    var placed_buffer: [max_labels_per_line]Placed = undefined;
    var count: usize = 0;
    for (labels) |label| {
        const start = @min(label.start, source.len);
        if (lineOf(source, start) != line) continue;
        if (count == placed_buffer.len) break;
        const end = std.math.clamp(label.end, start, range.end);
        const column = displayColumn(source[range.start..start]);
        placed_buffer[count] = .{
            .column = column,
            .width = @max(1, displayColumn(source[range.start..end]) - column),
            .label = label,
        };
        count += 1;
    }
    const placed = placed_buffer[0..count];
    std.mem.sort(Placed, placed, {}, struct {
        fn lessThan(_: void, a: Placed, b: Placed) bool {
            if (a.column != b.column) return a.column < b.column;
            return a.label.primary and !b.label.primary;
        }
    }.lessThan);

    var underline: Row = .{};
    for (placed) |p| {
        const byte: u8 = if (p.label.primary) '^' else '-';
        for (0..p.width) |offset| underline.set(p.column + offset, byte, p.mark());
    }

    // The rightmost label's message goes on the underline row; the others hang below.
    var hanging_buffer: [max_labels_per_line]Placed = undefined;
    var hanging_count: usize = 0;
    var inline_message: ?Placed = null;
    for (placed, 0..) |p, i| {
        if (p.label.message.len == 0) continue;
        if (i == placed.len - 1) {
            inline_message = p;
        } else {
            hanging_buffer[hanging_count] = p;
            hanging_count += 1;
        }
    }
    try underline.write(out, width, severity, style, if (inline_message) |p| .{ .text = p.label.message, .mark = p.mark() } else null);

    const hanging = hanging_buffer[0..hanging_count];
    if (hanging.len == 0) return;
    var connector: Row = .{};
    for (hanging) |p| connector.set(p.column, '|', p.mark());
    try connector.write(out, width, severity, style, null);
    var k = hanging.len;
    while (k > 0) {
        k -= 1;
        var row: Row = .{};
        for (hanging[0..k]) |p| row.set(p.column, '|', p.mark());
        // The message starts at the label's column: pad with spaces up to it.
        if (hanging[k].column > 0) row.set(hanging[k].column - 1, ' ', .none);
        try row.write(out, width, severity, style, .{ .text = hanging[k].label.message, .mark = hanging[k].mark(), .gap = false });
    }
}

const tab_width = 4;

/// The display width of `text`, which is on one line, with a tab as `tab_width` columns.
fn displayColumn(text: []const u8) usize {
    var width: usize = 0;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\t')) |tab| {
        width += unicode.displayWidth(rest[0..tab]) + tab_width;
        rest = rest[tab + 1 ..];
    }
    return width + unicode.displayWidth(rest);
}

/// The 0-based line that byte `offset` is on.
fn lineOf(source: []const u8, offset: usize) usize {
    return std.mem.count(u8, source[0..@min(offset, source.len)], "\n");
}

fn lineStart(source: []const u8, offset: usize) usize {
    const at = @min(offset, source.len);
    return if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |newline| newline + 1 else 0;
}

/// The bytes of the 0-based `line`, without its newline.
fn lineRange(source: []const u8, line: usize) struct { start: usize, end: usize } {
    var start: usize = 0;
    var n: usize = 0;
    while (n < line) : (n += 1) {
        start = (std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return .{ .start = source.len, .end = source.len }) + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    return .{ .start = start, .end = end };
}

fn digits(n: usize) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}

const testing = std.testing;

fn expectRendered(expected: []const u8, source: []const u8, diagnostic: Diagnostic) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try render(&out.writer, source, "query", diagnostic, .{});
    try testing.expectEqualStrings(expected, out.written());
}

test "one primary label" {
    const source = "SELECT nme FROM users";
    try expectRendered(
        \\error[1054]: unknown column `nme`
        \\ --> query:1:8
        \\  |
        \\1 | SELECT nme FROM users
        \\  |        ^^^ not in `users`
        \\  |
        \\  = help: did you mean `name`?
        \\
    , source, .{
        .code = "1054",
        .message = "unknown column `nme`",
        .labels = &.{.{ .start = 7, .end = 10, .message = "not in `users`", .primary = true }},
        .notes = &.{.{ .kind = .help, .text = "did you mean `name`?" }},
    });
}

test "labels on one line hang their messages below" {
    const source = "SELECT id FROM users u JOIN orders o";
    try expectRendered(
        \\error: ambiguous
        \\ --> query:1:8
        \\  |
        \\1 | SELECT id FROM users u JOIN orders o
        \\  |        ^^      -------      -------- `orders` has `id`
        \\  |        |       |
        \\  |        |       `users` has `id`
        \\  |        here
        \\
    , source, .{
        .message = "ambiguous",
        .labels = &.{
            .{ .start = 15, .end = 22, .message = "`users` has `id`" },
            .{ .start = 7, .end = 9, .message = "here", .primary = true },
            .{ .start = 28, .end = 36, .message = "`orders` has `id`" },
        },
    });
}

test "labels on several lines, with gaps" {
    const source = "SELECT\n  total\nFROM t\nWHERE\n  x = 1\n  AND total > 3";
    try expectRendered(
        \\error: where
        \\ --> query:6:7
        \\  |
        \\2 |   total
        \\  |   ----- defined here
        \\...
        \\6 |   AND total > 3
        \\  |       ^^^^^ used here
        \\
    , source, .{
        .message = "where",
        .labels = &.{
            .{ .start = 42, .end = 47, .message = "used here", .primary = true },
            .{ .start = 9, .end = 14, .message = "defined here" },
        },
    });
}

test "a line between two labelled lines is shown" {
    const source = "a\nb\nc";
    try expectRendered(
        \\error: x
        \\ --> query:1:1
        \\  |
        \\1 | a
        \\  | ^
        \\2 | b
        \\3 | c
        \\  | -
        \\
    , source, .{
        .message = "x",
        .labels = &.{ .{ .start = 0, .end = 1, .primary = true }, .{ .start = 4, .end = 5 } },
    });
}

test "an empty span at the end, multi-byte text, and a label running past its line" {
    const source = "SELECT 'é', (a\nFROM t";
    try expectRendered(
        \\error: x
        \\ --> query:2:7
        \\  |
        \\1 | SELECT 'é', (a
        \\  |             -- unclosed
        \\2 | FROM t
        \\  |       ^ end
        \\
    , source, .{
        .message = "x",
        .labels = &.{
            .{ .start = source.len, .end = source.len, .message = "end", .primary = true },
            .{ .start = 13, .end = source.len, .message = "unclosed" },
        },
    });
}

test "colour wraps the marks" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try renderSnippet(&out.writer, "x", "q", .{ .labels = &.{.{ .start = 0, .end = 1, .primary = true }} }, .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[1;31m^\x1b[0m") != null);
}
