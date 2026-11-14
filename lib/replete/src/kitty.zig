const std = @import("std");
const display = @import("display.zig");

pub const PromptOptions = struct {
    /// Kitty image IDs are terminal-global. Collisions are possible.
    image_id: u8,
    columns: usize,
    /// Unicode placeholder rows. Compact prompt images are generally only a
    /// few rows high; values up to the diacritic table below are supported.
    rows: usize = 2,
    gap: usize = 1,
    text: []const u8 = "> ",
    alignment: enum { top, middle, bottom } = .middle,
};

pub const PromptError = error{
    EmptyImage,
    InvalidDimensions,
};

const placeholder = "\u{10eeee}";
const png_chunk_bytes = 3072; // Encodes to the protocol maximum of 4096 bytes.

/// Build a normal ReplConfig.prompt containing a one-time Kitty PNG upload and
/// repaintable Unicode placeholder cells. The caller owns the returned slice.
pub fn pngPrompt(
    allocator: std.mem.Allocator,
    png: []const u8,
    options: PromptOptions,
) (std.mem.Allocator.Error || std.Io.Writer.Error || PromptError)![]u8 {
    if (png.len == 0) return error.EmptyImage;
    if (options.columns == 0 or options.rows == 0 or options.rows > row_diacritics.len) {
        return error.InvalidDimensions;
    }

    var result: std.Io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    const writer = &result.writer;

    // Readline ignore markers make the setup invisible to other prompt-aware
    // consumers. Replar extracts Kitty APCs and emits them only once.
    try writer.writeByte(0x01);
    var offset: usize = 0;
    var first = true;
    while (offset < png.len) {
        const end = @min(offset + png_chunk_bytes, png.len);
        const chunk = png[offset..end];
        const more: u1 = if (end < png.len) 1 else 0;

        if (first) {
            try writer.print(
                "\x1b_Ga=T,f=100,i={d},U=1,c={d},r={d},C=1,q=2,m={d};",
                .{ options.image_id, options.columns, options.rows, more },
            );
            first = false;
        } else {
            try writer.print("\x1b_Gq=2,m={d};", .{more});
        }

        var encoded: [4096]u8 = undefined;
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
        try writer.writeAll(std.base64.standard.Encoder.encode(encoded[0..encoded_len], chunk));
        try writer.writeAll("\x1b\\");
        offset = end;
    }
    try writer.writeByte(0x02);

    const edit_row = switch (options.alignment) {
        .top => 0,
        .middle => options.rows / 2,
        .bottom => options.rows - 1,
    };
    for (0..options.rows) |row| {
        // An 8-bit foreground color encodes the matching image ID. Only the
        // first cell needs a row diacritic; following cells inherit the row
        // and increment their column number.
        try writer.print("\x1b[38;5;{d}m", .{options.image_id});
        try writer.writeAll(placeholder);
        var diacritic_utf8: [4]u8 = undefined;
        const diacritic_len = std.unicode.utf8Encode(row_diacritics[row], &diacritic_utf8) catch unreachable;
        try writer.writeAll(diacritic_utf8[0..diacritic_len]);
        for (1..options.columns) |_| try writer.writeAll(placeholder);
        try writer.writeAll("\x1b[39m");

        if (row == edit_row) {
            for (0..options.gap) |_| try writer.writeByte(' ');
            try writer.writeAll(options.text);
            try writer.writeAll(display.prompt_insert_marker);
        }
        if (row + 1 < options.rows) try writer.writeByte('\n');
    }

    return result.toOwnedSlice();
}

// The beginning of Kitty's stable row/column diacritic table. Keeping the
// prompt API bounded avoids carrying a large protocol table for dimensions
// that are not useful in a line editor.
const row_diacritics = [_]u21{
    0x0305, 0x030d, 0x030e, 0x0310, 0x0312, 0x033d, 0x033e, 0x033f,
    0x0346, 0x034a, 0x034b, 0x034c, 0x0350, 0x0351, 0x0352, 0x0357,
    0x035b, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036a, 0x036b, 0x036c, 0x036d, 0x036e, 0x036f,
};

pub const max_rows = row_diacritics.len;

test "png prompt contains setup and a middle-aligned two-row placeholder" {
    const prompt = try pngPrompt(std.testing.allocator, "png", .{
        .image_id = 42,
        .columns = 3,
        .rows = 2,
        .gap = 1,
        .text = "> ",
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(
        u8,
        prompt,
        "\x01\x1b_Ga=T,f=100,i=42,U=1,c=3,r=2,C=1,q=2,m=0;cG5n\x1b\\\x02",
    ));
    try std.testing.expect(std.mem.endsWith(
        u8,
        prompt,
        "\x1b[38;5;42m\u{10eeee}\u{0305}\u{10eeee}\u{10eeee}\x1b[39m\n" ++
            "\x1b[38;5;42m\u{10eeee}\u{030d}\u{10eeee}\u{10eeee}\x1b[39m > " ++
            display.prompt_insert_marker,
    ));
}
