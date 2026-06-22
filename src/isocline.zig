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

pub fn setupHistory() void {
    C.ic_set_history("/Users/jeff/.local/state/thysql/history.txt", 5000);
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
