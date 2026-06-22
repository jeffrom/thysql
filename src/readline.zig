const std = @import("std");

const isocline = @import("isocline.zig");

pub fn freeLine(ptr: ?*anyopaque) void {
    isocline.freeMemory(ptr);
}

pub fn one(prompt: ?[:0]const u8) ?[:0]const u8 {
    return isocline.readline(prompt);
}

// fn wordCompleter(env: *isocline.ic_completion_env_t, word: [*c]const u8) callconv(.c) void {
//     const completions = [_][*:0]const u8{"select"};
//     // isocline.ic_add_completions(env, word, completions);
// }

pub fn setup() !void {
    isocline.setupHistory();
    isocline.disableFilenameCompletion();
    isocline.disablePromptMarker();

    // isocline.ic_set_default_completer(wordCompleter, null);
    // isocline.ic_enable_auto_tab(true);
}

pub fn rebuildCompletions() !void {
    // Hook for refreshing table and column completions after changing databases.
}

pub fn removeLastHistory() void {
    isocline.removeLastHistory();
}

pub fn addHistory(entry: [:0]const u8) void {
    isocline.addHistory(entry);
}
