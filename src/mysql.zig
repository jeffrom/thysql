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

        const result = C.mysql_store_result(self.conn);
        if (result == null) {
            std.debug.print("Store result failed: {s}\n", .{C.mysql_error(self.conn)});
            return error.StoreError;
        }
        return result;
    }
};

pub fn freeResult(result: [*]C.struct_st_mysql_res) void {
    C.mysql_free_result(result);
}

pub fn render_result(stdout: *std.Io.Writer, result: [*]C.struct_st_mysql_res) !void {
    // TODO ctrl+c should break this loop
    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }
        // const lengths = mysqlclient.mysql_fetch_lengths(result);
        const numFields = C.mysql_num_fields(result);
        try stdout.print("debug row: {any} {d}\n", .{ row, numFields });
        try stdout.flush();
        // var buffer = "";

        var i: u8 = 0;
        while (i < numFields) : (i += 1) {
            const field = C.mysql_fetch_field(result);
            const length = @max(4, field.*.length, field.*.max_length, field.*.name_length);
            field.*.max_length = length;
        }

        const lengths = C.mysql_fetch_lengths(result);

        _ = C.mysql_field_seek(result, 0);
        i = 0;
        while (true) : (i += 1) {
            const field = C.mysql_fetch_field(result);
            if (field == null) {
                break;
            }
            const name = field.*.name;
            std.debug.print("field name: {s}\n", .{name});

            std.debug.print("field type: {d}\n", .{field.*.type});

            std.debug.print("row data: {any}\n", .{row[i].*});

            const dataLength = lengths[i];
            const data = row[i];
            try printData(stdout, data, dataLength);
            // const serialized = try serializeType(field.*.type, row[i]);
            // try stdout.print(" {s} ", .{serialized});
        }
    }
}

fn printData(stdout: *std.Io.Writer, data: [*]const u8, len: usize) !void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        try stdout.printAsciiChar(data[i], .{});
    }
    try stdout.print("\n", .{});
    try stdout.flush();
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
