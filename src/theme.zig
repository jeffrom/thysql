//! The built-in colour themes for SQL highlighting. Each is a `replete.Theme`. The Catppuccin
//! flavours are built at comptime from a palette, so they share one mapping of styles to colours.

const std = @import("std");
const replete = @import("replete");
const OptionFile = @import("option_file.zig");

/// The default theme: replete's own colours, unchanged.
pub const default: replete.Theme = .{};

/// The terminal's own 16 ANSI colours, so the terminal's palette decides how they look. Cells
/// drawn with these follow the palette when the terminal switches light and dark, scrollback
/// included. Only SGR 30-37, 90-97 and attributes are used, never 256 or truecolour.
pub const ansi: replete.Theme = .{
    .keyword = "\x1b[1;35m",
    .keyword_nonreserved = "\x1b[35m",
    .identifier = "",
    .quoted_identifier = "\x1b[33m",
    .string = "\x1b[32m",
    .number = "\x1b[91m",
    .comment = "\x1b[3;90m",
    .operator = "\x1b[36m",
    .variable = "\x1b[31m",
    .function = "\x1b[34m",
    .delimiter = "\x1b[1;90m",
    .client_command = "\x1b[95m",
    .@"error" = "\x1b[4:3m\x1b[58:5:1m",
    .error_straight = "\x1b[4m\x1b[58:5:1m",
    .hint = "\x1b[90m",
    .diagnostic = "\x1b[31m",
};

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
    .{ .name = "ansi", .theme = ansi },
};

/// The built-in theme called `name`, or null. Case does not matter, and `_` is the same as `-`.
pub fn find(name: []const u8) ?replete.Theme {
    const canonical = canonicalName(name) orelse return null;
    for (builtins) |entry| {
        if (std.mem.eql(u8, entry.name, canonical)) return entry.theme;
    }
    return null;
}

/// The name of the built-in theme that `name` matches, as listed in `builtins`, or null.
/// Case does not matter, and `_` is the same as `-`.
pub fn canonicalName(name: []const u8) ?[]const u8 {
    // OptionFile.sameName ignores `_` against `-` but not case, so the name is lower-cased first.
    var lower: [64]u8 = undefined;
    if (name.len > lower.len) return null;
    const folded = std.ascii.lowerString(&lower, name);
    for (builtins) |entry| {
        if (OptionFile.sameName(entry.name, folded)) return entry.name;
    }
    return null;
}

/// The value of the `theme` setting: one theme, or a light and a dark theme, for the background.
pub const Choice = union(enum) {
    /// A built-in theme name, as `canonicalName` gives it.
    fixed: []const u8,
    pair: struct { light: []const u8, dark: []const u8 },
};

/// What a `theme` value may be, for error messages.
pub const valid_names = blk: {
    var text: []const u8 = "";
    for (builtins) |entry| text = text ++ entry.name ++ ", ";
    break :blk text ++ "catppuccin, or light:<name>,dark:<name>";
};

/// Every name that completion offers for `--theme`: the built-in names and `catppuccin`.
pub const completion_names = blk: {
    var names: [builtins.len + 1][]const u8 = undefined;
    for (builtins, 0..) |entry, i| names[i] = entry.name;
    names[builtins.len] = "catppuccin";
    const final = names;
    break :blk final[0..];
};

/// Parses a `theme` value: a built-in name, `catppuccin` (the latte and mocha pair), or
/// `light:<name>,dark:<name>` in either order. Spaces around `,` and `:` are allowed.
/// Null when the value is not valid.
pub fn parseChoice(spec: []const u8) ?Choice {
    const text = std.mem.trim(u8, spec, " \t");
    if (std.mem.indexOfAny(u8, text, ",:") == null) {
        if (std.ascii.eqlIgnoreCase(text, "catppuccin")) {
            return .{ .pair = .{ .light = "catppuccin-latte", .dark = "catppuccin-mocha" } };
        }
        return .{ .fixed = canonicalName(text) orelse return null };
    }

    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    if (std.mem.indexOfScalarPos(u8, text, comma + 1, ',') != null) return null;
    const first = parseSide(text[0..comma]) orelse return null;
    const second = parseSide(text[comma + 1 ..]) orelse return null;
    if (first.dark == second.dark) return null;
    return if (first.dark)
        .{ .pair = .{ .light = second.name, .dark = first.name } }
    else
        .{ .pair = .{ .light = first.name, .dark = second.name } };
}

/// One half of a `light:` or `dark:` pair.
const Side = struct { dark: bool, name: []const u8 };

fn parseSide(part: []const u8) ?Side {
    const colon = std.mem.indexOfScalar(u8, part, ':') orelse return null;
    const key = std.mem.trim(u8, part[0..colon], " \t");
    const name = canonicalName(std.mem.trim(u8, part[colon + 1 ..], " \t")) orelse return null;
    if (std.ascii.eqlIgnoreCase(key, "light")) return .{ .dark = false, .name = name };
    if (std.ascii.eqlIgnoreCase(key, "dark")) return .{ .dark = true, .name = name };
    return null;
}

/// The theme to draw with for `choice` on a dark or light background. A pair picks its side.
pub fn forChoice(choice: Choice, dark: bool) replete.Theme {
    const chosen = switch (choice) {
        .fixed => |fixed| fixed,
        .pair => |pair| if (dark) pair.dark else pair.light,
    };
    return find(chosen).?;
}

/// How long the terminal has to answer the background query before it is given up.
pub const background_timeout_ms = 100;

/// Whether the background is dark. The terminal is asked first. If it does not answer, COLORFGBG
/// is used, and if that is not set or not understood, the background is taken to be dark.
pub fn detectDark(io: std.Io, in_fd: std.posix.fd_t, out: *std.Io.Writer, colorfgbg: ?[]const u8) bool {
    if (replete.terminal.queryBackground(io, in_fd, out, background_timeout_ms)) |background| {
        return replete.terminal.isDark(background);
    }
    return darkFromColorFgBg(colorfgbg);
}

/// Whether a COLORFGBG value, `fg;bg` or `fg;x;bg`, names a dark background. The last field is
/// the background: 7 and 9-15 are light, and every other value, or no value, is dark.
pub fn darkFromColorFgBg(value: ?[]const u8) bool {
    const text = value orelse return true;
    const last = if (std.mem.lastIndexOfScalar(u8, text, ';')) |semi| text[semi + 1 ..] else text;
    const background = std.fmt.parseUnsigned(u8, std.mem.trim(u8, last, " \t"), 10) catch return true;
    return switch (background) {
        7, 9...15 => false,
        else => true,
    };
}

/// The choice in effect: `--theme` if given, else the connection's `theme`, else the config file's
/// `theme`, else `default`.
pub fn effective(flag: ?Choice, connection: ?Choice, file: ?Choice) Choice {
    return flag orelse connection orelse file orelse .{ .fixed = "default" };
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

test "ansi is found by name and uses only palette colours and attributes" {
    const theme = find("ansi").?;
    try std.testing.expect(find("ANSI") != null);
    try std.testing.expectEqualStrings("\x1b[1;35m", theme.keyword);
    for (std.enums.values(replete.Style)) |style| {
        const sequence = theme.sgr(style);
        try std.testing.expect(std.mem.indexOf(u8, sequence, "38;5;") == null);
        try std.testing.expect(std.mem.indexOf(u8, sequence, "38;2") == null);
    }
}

test "ansi errors keep their palette underline colour without undercurl" {
    var theme = find("ansi").?;
    try std.testing.expectEqualStrings("\x1b[4:3m\x1b[58:5:1m", theme.sgr(.@"error"));

    theme.undercurl = false;
    try std.testing.expectEqualStrings("\x1b[4m\x1b[58:5:1m", theme.sgr(.@"error"));
}

test "a theme value is a name, catppuccin, or a light and dark pair in either order" {
    try std.testing.expectEqualStrings("catppuccin-mocha", parseChoice("Catppuccin_Mocha").?.fixed);
    try std.testing.expectEqualStrings("default", parseChoice(" default ").?.fixed);

    const shorthand = parseChoice("catppuccin").?.pair;
    try std.testing.expectEqualStrings("catppuccin-latte", shorthand.light);
    try std.testing.expectEqualStrings("catppuccin-mocha", shorthand.dark);

    const light_first = parseChoice("light:catppuccin-frappe , dark : catppuccin-macchiato").?.pair;
    try std.testing.expectEqualStrings("catppuccin-frappe", light_first.light);
    try std.testing.expectEqualStrings("catppuccin-macchiato", light_first.dark);

    const dark_first = parseChoice("dark:catppuccin-mocha,light:catppuccin-latte").?.pair;
    try std.testing.expectEqualStrings("catppuccin-latte", dark_first.light);
    try std.testing.expectEqualStrings("catppuccin-mocha", dark_first.dark);
}

test "a bad theme value is null" {
    const bad = [_][]const u8{
        "",
        "catppuccin-espresso",
        "catppuccin-",
        "light:catppuccin-latte",
        "light:default,light:catppuccin-mocha",
        "light:default,dark:default,dark:default",
        "light:default,dark:nope",
        "default,dark:catppuccin-mocha",
        "middle:default,dark:catppuccin-mocha",
    };
    for (bad) |spec| {
        try std.testing.expectEqual(@as(?Choice, null), parseChoice(spec));
    }
}

test "a pair resolves to the theme for the background" {
    const pair = parseChoice("light:catppuccin-latte,dark:catppuccin-mocha").?;
    try std.testing.expectEqualStrings("\x1b[1;38;2;203;166;247m", forChoice(pair, true).keyword);
    try std.testing.expectEqualStrings(find("catppuccin-latte").?.keyword, forChoice(pair, false).keyword);
    try std.testing.expectEqualStrings((replete.Theme{}).keyword, forChoice(parseChoice("default").?, false).keyword);
}

test "COLORFGBG names a light background for 7 and 9-15, and a dark one otherwise" {
    try std.testing.expect(darkFromColorFgBg(null));
    try std.testing.expect(darkFromColorFgBg("15;0"));
    try std.testing.expect(darkFromColorFgBg("0;8"));
    try std.testing.expect(darkFromColorFgBg("0;6"));
    try std.testing.expect(darkFromColorFgBg("0;16"));
    try std.testing.expect(darkFromColorFgBg("0;default"));
    try std.testing.expect(darkFromColorFgBg("15;0;0"));
    try std.testing.expect(!darkFromColorFgBg("0;15"));
    try std.testing.expect(!darkFromColorFgBg("0;7"));
    try std.testing.expect(!darkFromColorFgBg("0;9"));
    try std.testing.expect(!darkFromColorFgBg("15;default;7"));
    try std.testing.expect(!darkFromColorFgBg("0; 7 "));
}

test "the flag wins over the connection, which wins over the config file, which wins over default" {
    const flag_choice: Choice = .{ .fixed = "catppuccin-mocha" };
    const connection_choice: Choice = .{ .fixed = "catppuccin-frappe" };
    const file_choice: Choice = .{ .fixed = "catppuccin-latte" };
    try std.testing.expectEqualStrings("catppuccin-mocha", effective(flag_choice, connection_choice, file_choice).fixed);
    try std.testing.expectEqualStrings("catppuccin-frappe", effective(null, connection_choice, file_choice).fixed);
    try std.testing.expectEqualStrings("catppuccin-latte", effective(null, null, file_choice).fixed);
    try std.testing.expectEqualStrings("default", effective(null, null, null).fixed);
}

test "completion offers each name and catppuccin" {
    try std.testing.expectEqual(builtins.len + 1, completion_names.len);
    try std.testing.expectEqualStrings("catppuccin", completion_names[completion_names.len - 1]);
}
