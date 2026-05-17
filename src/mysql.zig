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

    pub fn exec(self: DB, query: []const u8) !void {
        if (C.mysql_real_query(self.conn, query.ptr, query.len) != 0) {
            std.debug.print("Exec query failed: {s}\n", .{C.mysql_error(self.conn)});
            return error.ExecError;
        }

        const result = C.mysql_store_result(self.conn);
        if (result == null) {
            std.debug.print("Store result failed: {s}\n", .{C.mysql_error(self.conn)});
            return error.StoreError;
        }
        defer C.mysql_free_result(result);

        render_result(result);

        const affected = C.mysql_affected_rows(self.conn);
        std.debug.print("{d} row(s) affected\n", .{affected});
    }
};

fn render_result(result: [*c]C.struct_st_mysql_res) void {
    // TODO ctrl+c should break this loop
    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }
        // const lengths = mysqlclient.mysql_fetch_lengths(result);
        const numFields = C.mysql_num_fields(result);
        std.debug.print("debug row: {any} {d}\n", .{ row, numFields });
        // var buffer = "";

        var i: u8 = 0;
        while (i < numFields) : (i += 1) {
            const field = C.mysql_fetch_field(result);
            const length = @max(4, field.*.length, field.*.max_length, field.*.name_length);
            field.*.max_length = length;
        }

        _ = C.mysql_field_seek(result, 0);
        while (true) {
            const field = C.mysql_fetch_field(result);
            std.debug.print("field: {*}\n", .{field});
            if (field == null) {
                break;
            }
            const name = field.*.name;
            std.debug.print("field name: {s}\n", .{name});

            std.debug.print("field type: {d}\n", .{field.*.type});
        }
    }
}
