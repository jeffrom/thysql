//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Mysql = @import("mysql.zig");
const Readline = @import("readline.zig");

pub fn runREPL(allocator: Allocator) !void {
    const db = try Mysql.DB.init(allocator, .{
        .host = "127.0.0.1",
        .user = "root",
        .password = "123456",
        .database = "",
    });
    defer db.close();

    try Readline.setup();

    while (true) {
        const line = Readline.one("mysql") orelse break;
        std.debug.print("typed: {s}\n", .{line});
        try db.exec(line);

        Readline.freeLine(@ptrCast(@constCast(line)));
    }
}

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
