const std = @import("std");
const thysql = @import("thysql");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdoutBuffer: [1024]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writer(io, &stdoutBuffer);
    const stdout = &stdoutWriter.interface;

    var stderrBuffer: [1024]u8 = undefined;
    var stderrWriter = std.Io.File.stderr().writer(io, &stderrBuffer);
    const stderr = &stderrWriter.interface;

    const status = try thysql.runREPL(gpa, io, stdout, stderr, init.minimal.args, init.environ_map);

    try stdout.flush();
    try stderr.flush();

    if (status != 0) {
        std.process.exit(status);
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
