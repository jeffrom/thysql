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
