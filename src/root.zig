//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Mysql = @import("mysql.zig");
const Readline = @import("readline.zig");

fn readOneLine(db: Mysql.DB, stdout: *std.Io.Writer) !bool {
    const maybeLine = Readline.one("mysql");
    if (maybeLine == null) {
        return true;
    }
    defer Readline.freeLine(@ptrCast(@constCast(maybeLine)));

    const line = maybeLine.?;
    if (line.len == 0) {
        return false;
    }

    try stdout.print("typed: {s}\n", .{line});
    try stdout.flush();

    try db.exec(line);
    return false;
}

pub fn runREPL(allocator: Allocator, stdout: *std.Io.Writer) !void {
    const db = try Mysql.DB.init(allocator, .{
        .host = "127.0.0.1",
        .user = "root",
        .password = "123456",
        .database = "",
    });
    defer db.close();

    try Readline.setup();

    while (true) {
        const done = try readOneLine(db, stdout);
        if (done) {
            break;
        }
    }
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
