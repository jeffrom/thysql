const std = @import("std");

pub fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(value[i]) catch {
            width += 1;
            i += 1;
            continue;
        };
        if (i + sequence_len > value.len) {
            width += 1;
            i += 1;
            continue;
        }

        const cp = std.unicode.utf8Decode(value[i..][0..sequence_len]) catch {
            width += 1;
            i += 1;
            continue;
        };
        width += codepointDisplayWidth(cp);
        i += sequence_len;
    }
    return width;
}

pub fn escapedDisplayWidth(value: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (escapedAsciiByteWidth(value[i])) |byte_width| {
            width += byte_width;
            i += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(value[i]) catch {
            width += 4;
            i += 1;
            continue;
        };
        if (i + sequence_len > value.len) {
            width += 4;
            i += 1;
            continue;
        }

        const slice = value[i..][0..sequence_len];
        const cp = std.unicode.utf8Decode(slice) catch {
            width += 4;
            i += 1;
            continue;
        };
        if (cp >= 0x80 and cp < 0xa0) {
            width += 4;
        } else {
            width += displayWidth(slice);
        }
        i += sequence_len;
    }
    return width;
}

pub fn printEscapedValue(out: *std.Io.Writer, value: []const u8, max_width: usize) !void {
    var width: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (escapedAsciiByteWidth(value[i])) |byte_width| {
            if (width + byte_width > max_width) {
                return;
            }
            try printEscapedAsciiByte(out, value[i]);
            width += byte_width;
            i += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(value[i]) catch {
            if (width + 4 > max_width) {
                return;
            }
            try printHexEscapedByte(out, value[i]);
            width += 4;
            i += 1;
            continue;
        };
        if (i + sequence_len > value.len) {
            if (width + 4 > max_width) {
                return;
            }
            try printHexEscapedByte(out, value[i]);
            width += 4;
            i += 1;
            continue;
        }

        const slice = value[i..][0..sequence_len];
        const cp = std.unicode.utf8Decode(slice) catch {
            if (width + 4 > max_width) {
                return;
            }
            try printHexEscapedByte(out, value[i]);
            width += 4;
            i += 1;
            continue;
        };

        if (cp >= 0x80 and cp < 0xa0) {
            if (width + 4 > max_width) {
                return;
            }
            try printHexEscapedByte(out, @intCast(cp));
            width += 4;
        } else {
            const slice_width = displayWidth(slice);
            if (width + slice_width > max_width) {
                return;
            }
            try out.print("{s}", .{slice});
            width += slice_width;
        }
        i += sequence_len;
    }
}

pub fn hexDisplayWidth(value: []const u8) usize {
    return 2 + value.len * 2;
}

pub fn printHexValue(out: *std.Io.Writer, value: []const u8, max_width: usize) !void {
    if (max_width < 2) {
        return;
    }
    try out.print("0x", .{});
    var width: usize = 2;
    for (value) |byte| {
        if (width + 2 > max_width) {
            return;
        }
        try printHexByte(out, byte);
        width += 2;
    }
}

fn codepointDisplayWidth(cp: u21) usize {
    if (cp == 0) {
        return 0;
    }
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) {
        return 0;
    }
    if (isCombiningCodepoint(cp)) {
        return 0;
    }
    if (isWideCodepoint(cp)) {
        return 2;
    }
    return 1;
}

fn escapedAsciiByteWidth(byte: u8) ?usize {
    return switch (byte) {
        0 => 2,
        '\t' => 2,
        '\n' => 2,
        '\r' => 2,
        '\\' => 2,
        0x01...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => 4,
        else => null,
    };
}

fn printEscapedAsciiByte(out: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        0 => try out.print("\\0", .{}),
        '\t' => try out.print("\\t", .{}),
        '\n' => try out.print("\\n", .{}),
        '\r' => try out.print("\\r", .{}),
        '\\' => try out.print("\\\\", .{}),
        else => try printHexEscapedByte(out, byte),
    }
}

fn printHexEscapedByte(out: *std.Io.Writer, byte: u8) !void {
    try out.print("\\x", .{});
    try printHexByte(out, byte);
}

fn printHexByte(out: *std.Io.Writer, byte: u8) !void {
    const digits = "0123456789ABCDEF";
    try out.printAsciiChar(digits[byte >> 4], .{});
    try out.printAsciiChar(digits[byte & 0x0f], .{});
}

fn isCombiningCodepoint(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036f,
        0x1ab0...0x1aff,
        0x1dc0...0x1dff,
        0x20d0...0x20ff,
        0xfe00...0xfe0f,
        0xfe20...0xfe2f,
        => true,
        else => false,
    };
}

fn isWideCodepoint(cp: u21) bool {
    return switch (cp) {
        0x1100...0x115f,
        0x2329...0x232a,
        0x2e80...0xa4cf,
        0xac00...0xd7a3,
        0xf900...0xfaff,
        0xfe10...0xfe19,
        0xfe30...0xfe6f,
        0xff00...0xff60,
        0xffe0...0xffe6,
        0x1f300...0x1f64f,
        0x1f680...0x1f6ff,
        0x1f900...0x1f9ff,
        0x20000...0x3fffd,
        => true,
        else => false,
    };
}

test "displayWidth counts ASCII bytes as one column each" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
}

test "displayWidth counts composed accents as one column" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("é"));
}

test "displayWidth skips combining marks" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{301}"));
}

test "displayWidth counts CJK characters as two columns" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("東京"));
}

test "displayWidth treats malformed UTF-8 bytes as one column each" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth(&.{ 0xff, 'x' }));
}

fn expectEscaped(value: []const u8, max_width: usize, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try printEscapedValue(&writer.writer, value, max_width);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectHex(value: []const u8, max_width: usize, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try printHexValue(&writer.writer, value, max_width);

    try std.testing.expectEqualStrings(expect, writer.written());
}

test "escapedDisplayWidth counts escaped control bytes" {
    const bytes = [_]u8{ 'a', 0, '\n', '\t', '\\', 0x1b };
    try std.testing.expectEqual(@as(usize, 13), escapedDisplayWidth(&bytes));
}

test "printEscapedValue escapes unsafe bytes" {
    const bytes = [_]u8{ 'a', 0, 'b', '\n', 'c', '\t', 0x1b, '\\' };
    try expectEscaped(&bytes, std.math.maxInt(usize), "a\\0b\\nc\\t\\x1B\\\\");
}

test "printEscapedValue truncates on display width boundary" {
    try expectEscaped("abcd", 3, "abc");
}

test "printEscapedValue escapes malformed UTF-8 bytes" {
    try expectEscaped(&.{0xff}, std.math.maxInt(usize), "\\xFF");
}

test "printHexValue renders binary bytes" {
    try std.testing.expectEqual(@as(usize, 8), hexDisplayWidth(&.{ 0, 1, 0xff }));
    try expectHex(&.{ 0, 1, 0xff }, std.math.maxInt(usize), "0x0001FF");
}

test "printHexValue truncates to max width" {
    try expectHex(&.{ 0, 1, 2 }, 6, "0x0001");
}
