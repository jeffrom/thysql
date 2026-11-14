const std = @import("std");

const C = @import("isocline_c");
const history_file = @import("history_file.zig");

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

/// Creates the history directory if needed. Failures are ignored: history is
/// best-effort and must never stop the client from starting.
pub fn setupHistory(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    const path = (history_file.historyPath(allocator, env) catch return) orelse return;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    // isocline copies the file name, so freeing `path` afterwards is safe.
    C.ic_set_history(path.ptr, 5000);
}

pub const CompletionEnv = C.ic_completion_env_t;
/// The C header types the environment pointer as nullable in callbacks.
pub const CompleterFn = *const fn (?*CompletionEnv, [*c]const u8) callconv(.c) void;
pub const IsWordCharFn = *const fn ([*c]const u8, c_long) callconv(.c) bool;

/// Sets the completer for the whole line. `arg` is handed back by `completionArg`.
pub fn setDefaultCompleter(completer: CompleterFn, arg: ?*anyopaque) void {
    C.ic_set_default_completer(completer, arg);
}

/// Completes the word at the end of `prefix`, and calls `completer` with that word.
pub fn completeWord(env: *CompletionEnv, prefix: [*c]const u8, completer: CompleterFn, is_word_char: IsWordCharFn) void {
    C.ic_complete_word(env, prefix, completer, is_word_char);
}

/// Offers one completion for the word being completed.
pub fn addCompletion(env: *CompletionEnv, text: [:0]const u8) void {
    _ = C.ic_add_completion(env, text.ptr);
}

pub fn completionArg(env: *CompletionEnv) ?*anyopaque {
    return C.ic_completion_arg(env);
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
