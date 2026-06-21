//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Mysql = @import("mysql.zig");
const Readline = @import("readline.zig");

fn useDatabaseName(line: []const u8) ?[]const u8 {
    var remaining = std.mem.trim(u8, line, " \t\r\n");
    if (remaining.len == 0) {
        return null;
    }

    if (remaining[remaining.len - 1] == ';') {
        remaining = std.mem.trim(u8, remaining[0 .. remaining.len - 1], " \t\r\n");
    }

    if (remaining.len < 3 or !std.ascii.eqlIgnoreCase(remaining[0..3], "use")) {
        return null;
    }

    if (remaining.len > 3 and !std.ascii.isWhitespace(remaining[3])) {
        return null;
    }

    var name = std.mem.trim(u8, remaining[3..], " \t\r\n");
    if (name.len >= 2 and name[0] == '`' and name[name.len - 1] == '`') {
        name = name[1 .. name.len - 1];
    }
    return if (name.len == 0) null else name;
}

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

    if (useDatabaseName(line)) |database| {
        const database_z = try db.allocator.dupeZ(u8, database);
        defer db.allocator.free(database_z);

        db.selectDatabase(database_z) catch |err| {
            switch (err) {
                Mysql.DBError.ExecError => {
                    try db.renderLastError(stdout);
                    return false;
                },
                else => return true,
            }
        };

        try Readline.rebuildCompletions();
        try stdout.print("Database changed\n", .{});
        try stdout.flush();
        return false;
    }

    const exec_result = db.exec(line) catch |err| {
        switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                try db.renderLastError(stdout);
                return false;
            },
            // else => {
            //     return true;
            // },
        }
        // print error
    };
    switch (exec_result) {
        .result => |result| {
            defer Mysql.freeResult(result);
            try Mysql.render_result(stdout, result);
        },
        .ok => |ok| try Mysql.render_ok(stdout, ok),
    }

    // const affected = C.mysql_affected_rows(self.conn);
    // std.debug.print("{d} row(s) affected\n", .{affected});

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

test "detect USE database command" {
    try std.testing.expectEqualStrings("test", useDatabaseName("use test").?);
    try std.testing.expectEqualStrings("test", useDatabaseName("USE test;").?);
    try std.testing.expectEqualStrings("test", useDatabaseName("  use   test  ;  ").?);
    try std.testing.expectEqualStrings("my-db", useDatabaseName("use `my-db`;").?);
    try std.testing.expect(useDatabaseName("user test") == null);
    try std.testing.expect(useDatabaseName("select 1") == null);
}

test {
    _ = .{
        @import("mysql.zig"),
    };
}
