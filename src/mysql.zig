const std = @import("std");
const Allocator = std.mem.Allocator;

const C = @cImport({
    @cInclude("mysql/mysql.h");
});

pub const DBInfo = struct {
    host: [:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    port: u32 = 3306,
};

pub const DB = struct {
    conn: *C.struct_st_mysql,
    allocator: Allocator,

    pub fn init(allocator: Allocator, info: DBInfo) !DB {
        const db = C.mysql_init(null);

        if (db == null) {
            return error.InitError;
        }

        const conn_result = C.mysql_real_connect(
            db,
            info.host,
            info.user,
            info.password,
            info.database,
            info.port,
            null,
            C.CLIENT_MULTI_STATEMENTS,
        );
        if (conn_result == null) {
            std.debug.print("Connect to database failed: {s}\n", .{C.mysql_error(db)});
            return error.ConnectError;
        }

        return .{
            .conn = db,
            .allocator = allocator,
        };
    }

    pub fn close(self: DB) void {
        C.mysql_close(self.conn);
    }

    pub fn exec(self: DB, query: []const u8) ![*c]C.struct_st_mysql_res {
        if (C.mysql_real_query(self.conn, query.ptr, query.len) != 0) {
            std.debug.print("Exec query failed: {s}\n", .{C.mysql_error(self.conn)});
            return error.ExecError;
        }

        const result = C.mysql_use_result(self.conn);
        if (result == null) {
            std.debug.print("Use result failed: {s}\n", .{C.mysql_error(self.conn)});
            return error.UseResultError;
        }
        return result;
    }
};

pub fn freeResult(result: [*c]C.struct_st_mysql_res) void {
    C.mysql_free_result(result);
}

pub fn render_result(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res) !void {
    const numFields: usize = C.mysql_num_fields(result);

    _ = C.mysql_field_seek(result, 0);
    try printColumnSeparators(out, result, numFields);
    try out.print("+\n", .{});

    _ = C.mysql_field_seek(result, 0);
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        const name = field.*.name[0..field.*.name_length];

        try printHeaderCell(out, name, name.len);
    }
    try out.print("|\n", .{});

    _ = C.mysql_field_seek(result, 0);
    try printColumnSeparators(out, result, numFields);
    try out.print("+\n", .{});
    try out.flush();

    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }

        const lengths = C.mysql_fetch_lengths(result);

        try printMysqlRow(out, result, row, lengths, numFields);
        try out.flush();
    }
    try out.flush();
}

fn printColumnSeparators(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, numFields: usize) !void {
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        const name = field.*.name[0..field.*.name_length];

        try printColumnSeparator(out, name.len);
    }
}

fn printMysqlRow(
    out: *std.Io.Writer,
    result: [*c]C.struct_st_mysql_res,
    row: C.MYSQL_ROW,
    lengths: [*c]c_ulong,
    numFields: usize,
) !void {
    _ = C.mysql_field_seek(result, 0);
    for (0..numFields) |i| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        const name = field.*.name[0..field.*.name_length];
        const data_len = if (row[i] == null) "NULL".len else lengths[i];
        const value = if (row[i] == null) "NULL" else row[i][0..data_len];

        try printDataCell(out, value, name.len);
    }
    try out.print("|\n", .{});
}

fn printHeader(out: *std.Io.Writer, column_names: []const []const u8) !void {
    for (column_names) |name| {
        try printColumnSeparator(out, name.len);
    }
    try out.print("+\n", .{});

    for (column_names) |name| {
        try printHeaderCell(out, name, name.len);
    }
    try out.print("|\n", .{});

    for (column_names) |name| {
        try printColumnSeparator(out, name.len);
    }
    try out.print("+\n", .{});
}

fn printRow(out: *std.Io.Writer, column_names: []const []const u8, row: []const []const u8) !void {
    for (column_names, row) |name, value| {
        try printDataCell(out, value, name.len);
    }
    try out.print("|\n", .{});
}

fn printColumnSeparator(out: *std.Io.Writer, len: usize) !void {
    try out.printAsciiChar('+', .{});
    try printRowSeparator(out, len + 2);
}

fn printHeaderCell(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.printAsciiChar('|', .{});
    try out.printAsciiChar(' ', .{});
    try out.print("{s}", .{value});
    try printPadding(out, width - value.len);
    try out.printAsciiChar(' ', .{});
}

fn printDataCell(out: *std.Io.Writer, value: []const u8, width: usize) !void {
    try out.printAsciiChar('|', .{});
    try out.printAsciiChar(' ', .{});
    try printPadding(out, width - value.len);
    try out.print("{s}", .{value});
    try out.printAsciiChar(' ', .{});
}

fn printRowSeparator(out: *std.Io.Writer, len: usize) !void {
    for (0..len) |_| {
        try out.printAsciiChar('-', .{});
    }
}

fn printPadding(out: *std.Io.Writer, len: usize) !void {
    for (0..len) |_| {
        try out.printAsciiChar(' ', .{});
    }
}

fn serializeType(kind: u32, col: [*:0]const u8) ![*:0]const u8 {
    if (col == null) {
        return "NULL";
    }
    switch (kind) {
        8 => {
            return col;
        },
        else => {
            @panic("unhandled mysql data type");
        },
    }
    return "";
}

test "render SELECT 1" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    const columns = [_][]const u8{"1"};
    try printHeader(&writer.writer, &columns);
    try printRow(&writer.writer, &columns, &[_][]const u8{"1"});

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\
    ;
    try std.testing.expectEqualStrings(expect, writer.written());
}
