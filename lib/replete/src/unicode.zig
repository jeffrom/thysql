const std = @import("std");

pub fn codepointStartBefore(buf: []const u8, pos: usize) usize {
    std.debug.assert(pos > 0 and pos <= buf.len);

    var start = pos - 1;
    while (start > 0 and buf[start] & 0xc0 == 0x80) : (start -= 1) {}
    return start;
}

pub fn codepointLenAt(buf: []const u8, pos: usize) usize {
    std.debug.assert(pos < buf.len);

    const len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch return 1;
    if (pos + len > buf.len) return 1;
    _ = std.unicode.utf8Decode(buf[pos .. pos + len]) catch return 1;
    return len;
}

fn isZeroWidthCodepoint(cp: u21) bool {
    return cp == 0x200d or // Zero-width joiner
        cp == 0xfe0e or cp == 0xfe0f or // Variation selectors
        (cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or
        (cp >= 0x1f3fb and cp <= 0x1f3ff); // Emoji skin tones
}

fn isWideCodepoint(cp: u21) bool {
    return cp >= 0x1100 and
        (cp <= 0x115f or
            cp == 0x2329 or cp == 0x232a or
            (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
            (cp >= 0xac00 and cp <= 0xd7a3) or
            (cp >= 0xf900 and cp <= 0xfaff) or
            (cp >= 0xfe10 and cp <= 0xfe19) or
            (cp >= 0xfe30 and cp <= 0xfe6f) or
            (cp >= 0xff00 and cp <= 0xff60) or
            (cp >= 0xffe0 and cp <= 0xffe6) or
            (cp >= 0x1f1e6 and cp <= 0x1f1ff) or
            (cp >= 0x1f300 and cp <= 0x1faff) or
            (cp >= 0x20000 and cp <= 0x2ffff));
}

fn ansiCsiLen(bytes: []const u8) usize {
    if (bytes.len < 2 or bytes[0] != 0x1b or bytes[1] != '[') return 0;

    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
    if (i == bytes.len or bytes[i] < 0x40 or bytes[i] > 0x7e) return 0;
    return i + 1;
}

pub fn displayWidth(bytes: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    var afterZwj = false;

    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            const escapeLen = ansiCsiLen(bytes[i..]);
            if (escapeLen > 0) {
                i += escapeLen;
                continue;
            }
        }

        const codepointLen = codepointLenAt(bytes, i);
        const cp = std.unicode.utf8Decode(bytes[i .. i + codepointLen]) catch {
            width += 1;
            i += 1;
            continue;
        };

        if (afterZwj) {
            afterZwj = false;
        } else if (!isZeroWidthCodepoint(cp)) {
            width += if (isWideCodepoint(cp)) 2 else 1;
        }
        if (cp == 0x200d) afterZwj = true;
        i += codepointLen;
    }
    return width;
}

test "codepoint boundaries and display widths" {
    const text = "aé界🙂";
    try std.testing.expectEqual(@as(usize, 6), codepointStartBefore(text, text.len));
    try std.testing.expectEqual(@as(usize, 3), codepointStartBefore(text, 6));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("界"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🙂"));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("👩\u{200d}💻"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("\x1b[32m好\x1b[0m!"));
}
