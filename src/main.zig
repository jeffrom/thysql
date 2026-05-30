const std = @import("std");
const thysql = @import("thysql");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // defer arena.deinit();

    // const allocator = arena.allocator();

    var stdoutBuffer: [1024]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuffer);
    const stdout = &stdoutWriter.interface;

    try thysql.runREPL(gpa, stdout);

    try stdout.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
