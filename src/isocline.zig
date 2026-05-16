const std = @import("std");

const C = @cImport({
    @cInclude("isocline.h");
});

pub fn freeMemory(ptr: ?*anyopaque) void {
    C.ic_free(ptr);
}

pub fn strdup(s: []const u8) ?[]const u8 {
    const result = C.ic_strdup(s.ptr);
    return if (result) |p| std.mem.span(p) else null;
}

pub fn readline(prompt: ?[]const u8) ?[:0]const u8 {
    const result = C.ic_readline(if (prompt) |p| p.ptr else null);
    return if (result) |p| std.mem.span(p) else null;
}

pub fn setupHistory() void {
    C.ic_set_history(null, 5000);
}
