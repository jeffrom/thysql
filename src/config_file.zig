//! The general config file: `$XDG_CONFIG_HOME/thysql/config`, or `$HOME/.config/thysql/config`
//! when XDG_CONFIG_HOME is unset or empty. It has `key = value` lines and `#` comments, as the
//! connection files do. Its only key is `theme`. An unknown key is an error that names the file
//! and line, and a missing file means the defaults.

const std = @import("std");
const Allocator = std.mem.Allocator;
const OptionFile = @import("option_file.zig");
const Theme = @import("theme.zig");

pub const Error = error{ ConfigFailed, OutOfMemory };

/// The settings from the config file. A setting that is not in the file is null.
pub const Config = struct {
    theme: ?Theme.Choice = null,
};

const file_name = "config";
const theme_key = "theme";
const max_file_size = 64 * 1024;
const whitespace = " \t\r\n\x0b\x0c";

/// The thysql config folder: `$XDG_CONFIG_HOME/thysql` when XDG_CONFIG_HOME is set and non-empty,
/// else `$HOME/.config/thysql`. Null when neither is set. The connections root lives inside it.
pub fn dir(allocator: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |xdg| {
        return try std.fs.path.join(allocator, &.{ xdg, "thysql" });
    }
    if (nonEmpty(env.get("HOME"))) |home| {
        return try std.fs.path.join(allocator, &.{ home, ".config", "thysql" });
    }
    return null;
}

/// Reads the config file. A missing file, or no config folder, gives the defaults. Errors are
/// printed to `stderr` as `path:line: message`, and then `error.ConfigFailed` is returned.
pub fn load(allocator: Allocator, io: std.Io, env: *const std.process.Environ.Map, stderr: *std.Io.Writer) Error!Config {
    const folder = (try dir(allocator, env)) orelse return .{};
    defer allocator.free(folder);
    const path = try std.fs.path.join(allocator, &.{ folder, file_name });
    defer allocator.free(path);

    const text = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            stderr.print("could not read \"{s}\"\n", .{path}) catch {};
            return error.ConfigFailed;
        },
    };
    defer allocator.free(text);
    return parse(text, path, stderr);
}

/// Parses the text of a config file. `path` is used only in messages.
pub fn parse(text: []const u8, path: []const u8, stderr: *std.Io.Writer) Error!Config {
    var config: Config = .{};
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const equals = std.mem.indexOfScalar(u8, line, '=') orelse {
            return failAt(stderr, path, line_number, "a setting needs the form key = value", .{});
        };
        const key = std.mem.trim(u8, line[0..equals], whitespace);
        const value = std.mem.trim(u8, line[equals + 1 ..], whitespace);
        if (!OptionFile.sameName(key, theme_key)) {
            return failAt(stderr, path, line_number, "unknown key \"{s}\"", .{key});
        }
        config.theme = Theme.parseChoice(value) orelse {
            return failAt(stderr, path, line_number, "invalid theme \"{s}\"; expected {s}", .{ value, Theme.valid_names });
        };
    }
    return config;
}

/// Reports `path:line: message` and returns the error.
fn failAt(stderr: *std.Io.Writer, path: []const u8, line: usize, comptime format: []const u8, args: anytype) Error {
    stderr.print("{s}:{d}: ", .{ path, line }) catch {};
    stderr.print(format ++ "\n", args) catch {};
    return error.ConfigFailed;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len > 0) text else null;
}

test "the config folder is XDG_CONFIG_HOME/thysql when set and non-empty, else HOME/.config/thysql" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try dir(allocator, &env));

    try env.put("HOME", "/home/t");
    const home_dir = (try dir(allocator, &env)).?;
    defer allocator.free(home_dir);
    try std.testing.expectEqualStrings("/home/t/.config/thysql", home_dir);

    try env.put("XDG_CONFIG_HOME", "");
    const empty_xdg = (try dir(allocator, &env)).?;
    defer allocator.free(empty_xdg);
    try std.testing.expectEqualStrings("/home/t/.config/thysql", empty_xdg);

    try env.put("XDG_CONFIG_HOME", "/xdg");
    const xdg_dir = (try dir(allocator, &env)).?;
    defer allocator.free(xdg_dir);
    try std.testing.expectEqualStrings("/xdg/thysql", xdg_dir);
}

test "the theme key is read, comments and blank lines are skipped, and the last one wins" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const text = "# colours\n\n  theme = light:catppuccin-latte , dark:catppuccin-frappe \ntheme=catppuccin-mocha\n";
    const config = try parse(text, "config", &stderr.writer);
    try std.testing.expectEqualStrings("catppuccin-mocha", config.theme.?.fixed);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "an empty file gives the defaults" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const config = try parse("# nothing set\n", "config", &stderr.writer);
    try std.testing.expectEqual(@as(?Theme.Choice, null), config.theme);
}

test "an unknown key names the file and line" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.ConfigFailed, parse("theme = default\nfont = mono\n", "/x/thysql/config", &stderr.writer));
    try std.testing.expectEqualStrings("/x/thysql/config:2: unknown key \"font\"\n", stderr.written());
}

test "an invalid theme names the file and line, and lists the names" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.ConfigFailed, parse("theme = purple\n", "config", &stderr.writer));
    try std.testing.expect(std.mem.startsWith(u8, stderr.written(), "config:1: invalid theme \"purple\"; expected default, catppuccin-latte"));
}

test "a line without = is an error, and a missing file gives the defaults" {
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectError(error.ConfigFailed, parse("theme\n", "config", &stderr.writer));
    try std.testing.expectEqualStrings("config:1: a setting needs the form key = value\n", stderr.written());

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/nonexistent-thysql-test-dir");
    const config = try load(std.testing.allocator, std.testing.io, &env, &stderr.writer);
    try std.testing.expectEqual(@as(?Theme.Choice, null), config.theme);
}
