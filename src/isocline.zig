const std = @import("std");

const C = @import("isocline_c");

pub fn freeMemory(ptr: ?*anyopaque) void {
    C.ic_free(ptr);
}

pub fn strdup(s: []const u8) ?[]const u8 {
    const result = C.ic_strdup(s.ptr);
    return if (result) |p| std.mem.span(p) else null;
}

pub fn readline(prompt: ?[:0]const u8) ?[:0]const u8 {
    const result = C.ic_readline(if (prompt) |p| p.ptr else null);
    return if (result) |p| std.mem.span(p) else null;
}

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

/// Creates the history directory if needed. Failures are ignored: history is
/// best-effort and must never stop the client from starting.
pub fn setupHistory(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    const path = (historyPath(allocator, env) catch return) orelse return;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    // isocline copies the file name, so freeing `path` afterwards is safe.
    C.ic_set_history(path.ptr, 5000);
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

pub fn disableFilenameCompletion() void {
    C.ic_set_default_completer(null, null);
}

pub fn disablePromptMarker() void {
    C.ic_set_prompt_marker("", "");
}

pub fn removeLastHistory() void {
    C.ic_history_remove_last();
}

pub fn addHistory(entry: [:0]const u8) void {
    C.ic_history_add(entry.ptr);
}
