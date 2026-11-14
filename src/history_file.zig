//! Where the REPL keeps its history, and the rules for finding it. The file itself is
//! read and written by replete's `FileHistory`, which `readline.zig` drives.

const std = @import("std");

/// Resolves the history file: $MYSQL_HISTFILE, then $XDG_STATE_HOME/thysql/history,
/// then $HOME/.local/state/thysql/history. Empty variables count as unset.
/// Returns null when none of them is set. Caller frees the result.
pub fn historyPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[:0]u8 {
    if (nonEmptyEnv(env, "MYSQL_HISTFILE")) |path| {
        return try allocator.dupeSentinel(u8, path, 0);
    }
    if (nonEmptyEnv(env, "XDG_STATE_HOME")) |state_home| {
        return try std.fs.path.joinZ(allocator, &.{ state_home, "thysql", "history" });
    }
    if (nonEmptyEnv(env, "HOME")) |home| {
        return try std.fs.path.joinZ(allocator, &.{ home, ".local", "state", "thysql", "history" });
    }
    return null;
}

fn nonEmptyEnv(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

test "history path prefers MYSQL_HISTFILE" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("MYSQL_HISTFILE", "/tmp/custom-history");
    try env.put("XDG_STATE_HOME", "/tmp/state");
    try env.put("HOME", "/tmp/home");

    const path = (try historyPath(allocator, &env)).?;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/custom-history", path);
}

test "history path falls back to XDG_STATE_HOME then HOME" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/home");
    try env.put("XDG_STATE_HOME", "/tmp/state");

    const xdg = (try historyPath(allocator, &env)).?;
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/tmp/state/thysql/history", xdg);

    try env.put("XDG_STATE_HOME", "");
    const home = (try historyPath(allocator, &env)).?;
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/tmp/home/.local/state/thysql/history", home);
}

test "history path is null without any location variable" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try std.testing.expect((try historyPath(allocator, &env)) == null);
}
