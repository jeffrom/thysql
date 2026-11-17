//! The built-in colour themes for SQL highlighting. Each is a `replete.Theme`. The Catppuccin
//! flavours are built at comptime from a palette, so they share one mapping of styles to colours.

const std = @import("std");
const replete = @import("replete");
const OptionFile = @import("option_file.zig");

/// The default theme: replete's own colours, unchanged.
pub const default: replete.Theme = .{};

/// The colours of one Catppuccin flavour, as 0xRRGGBB.
pub const Palette = struct {
    flamingo: u24,
    pink: u24,
    mauve: u24,
    red: u24,
    maroon: u24,
    peach: u24,
    yellow: u24,
    green: u24,
    teal: u24,
    sky: u24,
    blue: u24,
    overlay2: u24,
    overlay1: u24,
};

pub const latte: Palette = .{
    .flamingo = 0xdd7878,
    .pink = 0xea76cb,
    .mauve = 0x8839ef,
    .red = 0xd20f39,
    .maroon = 0xe64553,
    .peach = 0xfe640b,
    .yellow = 0xdf8e1d,
    .green = 0x40a02b,
    .teal = 0x179299,
    .sky = 0x04a5e5,
    .blue = 0x1e66f5,
    .overlay2 = 0x7c7f93,
    .overlay1 = 0x8c8fa1,
};

pub const frappe: Palette = .{
    .flamingo = 0xeebebe,
    .pink = 0xf4b8e4,
    .mauve = 0xca9ee6,
    .red = 0xe78284,
    .maroon = 0xea999c,
    .peach = 0xef9f76,
    .yellow = 0xe5c890,
    .green = 0xa6d189,
    .teal = 0x81c8be,
    .sky = 0x99d1db,
    .blue = 0x8caaee,
    .overlay2 = 0x949cbb,
    .overlay1 = 0x838ba7,
};

pub const macchiato: Palette = .{
    .flamingo = 0xf0c6c6,
    .pink = 0xf5bde6,
    .mauve = 0xc6a0f6,
    .red = 0xed8796,
    .maroon = 0xee99a0,
    .peach = 0xf5a97f,
    .yellow = 0xeed49f,
    .green = 0xa6da95,
    .teal = 0x8bd5ca,
    .sky = 0x91d7e3,
    .blue = 0x8aadf4,
    .overlay2 = 0x939ab7,
    .overlay1 = 0x8087a2,
};

pub const mocha: Palette = .{
    .flamingo = 0xf2cdcd,
    .pink = 0xf5c2e7,
    .mauve = 0xcba6f7,
    .red = 0xf38ba8,
    .maroon = 0xeba0ac,
    .peach = 0xfab387,
    .yellow = 0xf9e2af,
    .green = 0xa6e3a1,
    .teal = 0x94e2d5,
    .sky = 0x89dceb,
    .blue = 0x89b4fa,
    .overlay2 = 0x9399b2,
    .overlay1 = 0x7f849c,
};

/// The theme for a palette, with styles coloured as the Catppuccin style guide gives them.
pub fn fromPalette(comptime p: Palette) replete.Theme {
    @setEvalBranchQuota(100_000);
    return .{
        .keyword = sgr("1;" ++ fg(p.mauve)),
        .keyword_nonreserved = sgr(fg(p.mauve)),
        .identifier = "",
        .quoted_identifier = sgr(fg(p.flamingo)),
        .string = sgr(fg(p.green)),
        .number = sgr(fg(p.peach)),
        .comment = sgr("3;" ++ fg(p.overlay2)),
        .operator = sgr(fg(p.sky)),
        .variable = sgr(fg(p.maroon)),
        .function = sgr(fg(p.blue)),
        .delimiter = sgr("1;" ++ fg(p.overlay2)),
        .client_command = sgr(fg(p.pink)),
        .@"error" = sgr("4:3") ++ underlineColor(p.red),
        .error_straight = sgr("4") ++ underlineColor(p.red),
        .hint = sgr(fg(p.overlay1)),
        .diagnostic = sgr(fg(p.red)),
    };
}

/// The built-in themes, by name. `find` looks here.
pub const builtins = [_]struct { name: []const u8, theme: replete.Theme }{
    .{ .name = "default", .theme = default },
    .{ .name = "catppuccin-latte", .theme = fromPalette(latte) },
    .{ .name = "catppuccin-frappe", .theme = fromPalette(frappe) },
    .{ .name = "catppuccin-macchiato", .theme = fromPalette(macchiato) },
    .{ .name = "catppuccin-mocha", .theme = fromPalette(mocha) },
};

/// The built-in theme called `name`, or null. Case does not matter, and `_` is the same as `-`.
pub fn find(name: []const u8) ?replete.Theme {
    // OptionFile.sameName ignores `_` against `-` but not case, so the name is lower-cased first.
    var lower: [64]u8 = undefined;
    if (name.len > lower.len) return null;
    const folded = std.ascii.lowerString(&lower, name);
    for (builtins) |entry| {
        if (OptionFile.sameName(entry.name, folded)) return entry.theme;
    }
    return null;
}

fn sgr(comptime params: []const u8) []const u8 {
    return std.fmt.comptimePrint("\x1b[{s}m", .{params});
}

fn fg(comptime color: u24) []const u8 {
    const c = rgb(color);
    return std.fmt.comptimePrint("38;2;{d};{d};{d}", .{ c[0], c[1], c[2] });
}

fn underlineColor(comptime color: u24) []const u8 {
    const c = rgb(color);
    return std.fmt.comptimePrint("\x1b[58:2::{d}:{d}:{d}m", .{ c[0], c[1], c[2] });
}

fn rgb(comptime color: u24) [3]u8 {
    return .{ @intCast(color >> 16), @intCast((color >> 8) & 0xff), @intCast(color & 0xff) };
}

test "default is replete's own theme" {
    try std.testing.expectEqualStrings((replete.Theme{}).keyword, find("default").?.keyword);
}

test "names match without regard to case, and - and _ are the same" {
    try std.testing.expect(find("Catppuccin_Mocha") != null);
    try std.testing.expect(find("CATPPUCCIN-latte") != null);
    try std.testing.expect(find("catppuccin-frappe") != null);
    try std.testing.expect(find("Catppuccin_Macchiato") != null);
    try std.testing.expect(find("catppuccin") == null);
    try std.testing.expect(find("catppuccin-espresso") == null);
    try std.testing.expect(find("") == null);
}

test "every Catppuccin style but identifier has a colour" {
    const mocha_theme = find("catppuccin-mocha").?;
    for (std.enums.values(replete.Style)) |style| {
        if (style != .plain and style != .identifier) {
            try std.testing.expect(mocha_theme.sgr(style).len > 0);
        }
    }
    try std.testing.expectEqualStrings("", mocha_theme.sgr(.identifier));
}

test "the Catppuccin flavours differ" {
    const keywords = [_][]const u8{
        find("catppuccin-latte").?.keyword,
        find("catppuccin-frappe").?.keyword,
        find("catppuccin-macchiato").?.keyword,
        find("catppuccin-mocha").?.keyword,
    };
    for (keywords, 0..) |a, i| {
        for (keywords[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "mocha keyword is bold mauve" {
    try std.testing.expectEqualStrings("\x1b[1;38;2;203;166;247m", find("catppuccin-mocha").?.keyword);
}

test "mocha error is a red curly underline, and keeps its colour without undercurl" {
    var theme = find("catppuccin-mocha").?;
    try std.testing.expectEqualStrings("\x1b[4:3m\x1b[58:2::243:139:168m", theme.sgr(.@"error"));

    theme.undercurl = false;
    try std.testing.expectEqualStrings("\x1b[4m\x1b[58:2::243:139:168m", theme.sgr(.@"error"));
}
