const std = @import("std");
const Allocator = std.mem.Allocator;

const mysqlclient = @cImport({
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
    conn: *mysqlclient.struct_st_mysql,
    allocator: Allocator,

    pub fn init(allocator: Allocator, info: DBInfo) !DB {
        const db = mysqlclient.mysql_init(null);

        if (db == null) {
            return error.InitError;
        }

        const conn_result = mysqlclient.mysql_real_connect(
            db,
            info.host,
            info.user,
            info.password,
            info.database,
            info.port,
            null,
            mysqlclient.CLIENT_MULTI_STATEMENTS,
        );
        if (conn_result == null) {
            std.debug.print("Connect to database failed: {s}\n", .{mysqlclient.mysql_error(db)});
            return error.ConnectError;
        }

        return .{
            .conn = db,
            .allocator = allocator,
        };
    }

    pub fn close(self: DB) void {
        mysqlclient.mysql_close(self.conn);
    }

    pub fn exec(self: DB, query: []const u8) !void {
        if (mysqlclient.mysql_real_query(self.conn, query.ptr, query.len) != 0) {
            std.debug.print("Exec query failed: {s}\n", .{mysqlclient.mysql_error(self.conn)});
            return error.ExecError;
        }

        const result = mysqlclient.mysql_store_result(self.conn);
        if (result == null) {
            std.debug.print("Store result failed: {s}\n", .{mysqlclient.mysql_error(self.conn)});
            return error.StoreError;
        }
        defer mysqlclient.mysql_free_result(result);

        while (mysqlclient.mysql_fetch_row(result)) |row| {
            std.debug.print("row: {*}\n", .{row[0]});
        }
    }
};
