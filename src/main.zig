const std = @import("std");
const thysql = @import("thysql");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdoutBuffer: [1024]u8 = undefined;
    var stdoutWriter = std.Io.File.stdout().writerStreaming(io, &stdoutBuffer);
    const stdout = &stdoutWriter.interface;

    var stderrBuffer: [1024]u8 = undefined;
    var stderrWriter = std.Io.File.stderr().writerStreaming(io, &stderrBuffer);
    const stderr = &stderrWriter.interface;

    // A reader that closes the pipe early, as in `thysql --help | head -1`, makes writes fail.
    // That is not an error worth a stack trace: stop quietly, as `complete` does.
    const status = thysql.runREPL(gpa, io, stdout, stderr, init.minimal.args, init.environ_map) catch |err| switch (err) {
        error.WriteFailed => std.process.exit(0),
        else => return err,
    };

    stdout.flush() catch std.process.exit(0);
    stderr.flush() catch {};

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
