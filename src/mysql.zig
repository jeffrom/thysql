const std = @import("std");
const Allocator = std.mem.Allocator;

const C = @import("mysql_c");

pub const DBInfo = struct {
    host: [:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    database: [:0]const u8,
    port: u32 = 3306,
};

pub const DBError = error{ ExecError, StoreResultError };

pub const OKResult = struct {
    affected_rows: u64,
    warnings: u32,
    info: ?[]const u8,
};

pub const ExecResult = union(enum) {
    result: [*c]C.struct_st_mysql_res,
    ok: OKResult,
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

    pub fn selectDatabase(self: DB, database: [:0]const u8) DBError!void {
        if (C.mysql_select_db(self.conn, database.ptr) != 0) {
            return DBError.ExecError;
        }
    }

    pub fn exec(self: DB, query: []const u8) DBError!ExecResult {
        if (C.mysql_real_query(self.conn, query.ptr, query.len) != 0) {
            return DBError.ExecError;
        }

        const result = self.mysqlStoreResultForLazy() catch return DBError.StoreResultError;
        if (result) |res| {
            return .{ .result = res };
        }

        const info = C.mysql_info(self.conn);
        return .{ .ok = .{
            .affected_rows = C.mysql_affected_rows(self.conn),
            .warnings = C.mysql_warning_count(self.conn),
            .info = if (info == null) null else std.mem.sliceTo(info, 0),
        } };
    }

    fn mysqlStoreResultForLazy(self: DB) DBError!?[*c]C.struct_st_mysql_res {
        if (C.mysql_store_result(self.conn)) |result| {
            return result;
        }

        const message = C.mysql_error(self.conn);
        if (message != null and message[0] != 0) {
            return DBError.StoreResultError;
        }

        return null;
    }

    pub fn renderLastError(self: DB, out: *std.Io.Writer) !void {
        const errno = C.mysql_errno(self.conn);
        const sqlstate = C.mysql_sqlstate(self.conn);
        const message = C.mysql_error(self.conn);

        try render_error(out, errno, if (sqlstate == null) null else std.mem.sliceTo(sqlstate, 0), std.mem.sliceTo(message, 0));
    }
};

pub fn freeResult(result: [*c]C.struct_st_mysql_res) void {
    C.mysql_free_result(result);
}

pub fn render_ok(out: *std.Io.Writer, ok: OKResult) !void {
    if (ok.affected_rows == C.MYSQL_COUNT_ERROR) {
        try out.print("Query OK", .{});
    } else {
        try out.print("Query OK, {} {s} affected", .{
            ok.affected_rows,
            if (ok.affected_rows == 1) "row" else "rows",
        });
    }

    if (ok.warnings != 0) {
        try out.print(", {} warning{s}", .{
            ok.warnings,
            if (ok.warnings == 1) "" else "s",
        });
    }

    try out.print("\n", .{});
    if (ok.info) |info| {
        try out.print("{s}\n", .{info});
    }
    try out.print("\n", .{});
    try out.flush();
}

pub fn render_error(out: *std.Io.Writer, errno: u32, sqlstate: ?[]const u8, message: []const u8) !void {
    if (errno == 0) {
        try out.print("ERROR: {s}\n", .{message});
    } else if (sqlstate) |state| {
        try out.print("ERROR {} ({s}): {s}\n", .{ errno, state, message });
    } else {
        try out.print("ERROR {}: {s}\n", .{ errno, message });
    }
    try out.flush();
}

pub fn render_result(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res) !void {
    const numFields: usize = C.mysql_num_fields(result);

    if (C.mysql_num_rows(result) == 0) {
        try out.print("Empty set\n\n", .{});
        try out.flush();
        return;
    }

    _ = C.mysql_field_seek(result, 0);
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        field.*.max_length = @max(field.*.max_length, field.*.name_length);
        if (field.*.max_length < 4 and (field.*.flags & C.NOT_NULL_FLAG) == 0) {
            field.*.max_length = 4;
        }
    }

    if (result.*.data != null) {
        while (C.mysql_fetch_row(result)) |row| {
            if (row == null) {
                break;
            }

            const lengths = C.mysql_fetch_lengths(result);
            _ = C.mysql_field_seek(result, 0);
            for (0..numFields) |i| {
                const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
                const dataLength = if (row[i] == null) "NULL".len else lengths[i];
                field.*.max_length = @max(field.*.max_length, dataLength);
            }
        }
        C.mysql_data_seek(result, 0);
    }

    _ = C.mysql_field_seek(result, 0);
    try printColumnSeparators(out, result, numFields);
    try out.print("+\n", .{});

    _ = C.mysql_field_seek(result, 0);
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        const name = field.*.name[0..field.*.name_length];

        try printHeaderCell(out, name, field.*.max_length);
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
    }

    _ = C.mysql_field_seek(result, 0);
    try printColumnSeparators(out, result, numFields);
    try out.print("+\n", .{});
    try out.flush();
}

pub fn render_result_vertical(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res) !void {
    const numFields: usize = C.mysql_num_fields(result);

    if (C.mysql_num_rows(result) == 0) {
        try out.print("Empty set\n\n", .{});
        try out.flush();
        return;
    }

    _ = C.mysql_field_seek(result, 0);
    var maxNameLength: usize = 0;
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        maxNameLength = @max(maxNameLength, field.*.name_length);
    }

    C.mysql_data_seek(result, 0);
    var rowCount: usize = 1;
    while (C.mysql_fetch_row(result)) |row| {
        if (row == null) {
            break;
        }

        try out.print("*************************** {}. row ***************************\n", .{rowCount});

        const lengths = C.mysql_fetch_lengths(result);
        _ = C.mysql_field_seek(result, 0);
        for (0..numFields) |i| {
            const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
            const name = field.*.name[0..field.*.name_length];
            try printPadding(out, maxNameLength - name.len);
            try out.print("{s}: ", .{name});
            if (row[i] == null) {
                try out.print("NULL\n", .{});
            } else {
                try out.print("{s}\n", .{row[i][0..lengths[i]]});
            }
        }

        rowCount += 1;
    }
    try out.flush();
}

fn printColumnSeparators(out: *std.Io.Writer, result: [*c]C.struct_st_mysql_res, numFields: usize) !void {
    for (0..numFields) |_| {
        const field = C.mysql_fetch_field(result) orelse return error.FetchFieldError;
        try printColumnSeparator(out, field.*.max_length);
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
        // const name = field.*.name[0..field.*.name_length];
        const dataLength = if (row[i] == null) "NULL".len else lengths[i];
        const value = if (row[i] == null) "NULL" else row[i][0..dataLength];

        try printDataCell(out, value, field.*.max_length, isNumericType(field.*.type));
    }
    try out.print("|\n", .{});
}

fn printHeader(out: *std.Io.Writer, column_names: []const []const u8, maxLength: usize) !void {
    for (column_names) |_| {
        try printColumnSeparator(out, maxLength);
    }
    try out.print("+\n", .{});

    for (column_names) |name| {
        try printHeaderCell(out, name, maxLength);
    }
    try out.print("|\n", .{});

    for (column_names) |_| {
        try printColumnSeparator(out, maxLength);
    }
    try out.print("+\n", .{});
}

fn printRow(out: *std.Io.Writer, column_names: []const []const u8, row: []const []const u8, maxLength: usize) !void {
    for (column_names, row) |_, value| {
        try printDataCell(out, value, maxLength, true);
    }
    try out.print("|\n", .{});

    for (column_names) |_| {
        try printColumnSeparator(out, maxLength);
    }
    try out.print("+\n", .{});
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

fn printDataCell(out: *std.Io.Writer, value: []const u8, width: usize, right_align: bool) !void {
    try out.printAsciiChar('|', .{});
    try out.printAsciiChar(' ', .{});
    if (right_align) {
        try printPadding(out, if (width >= value.len) width - value.len else 0);
        try out.print("{s}", .{value});
    } else {
        try out.print("{s}", .{value});
        try printPadding(out, if (width >= value.len) width - value.len else 0);
    }
    try out.printAsciiChar(' ', .{});
}

fn isNumericType(kind: C.enum_enum_field_types) bool {
    return (kind <= C.MYSQL_TYPE_INT24 and kind != C.MYSQL_TYPE_TIMESTAMP) or
        kind == C.MYSQL_TYPE_YEAR or
        kind == C.MYSQL_TYPE_NEWDECIMAL;
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

fn mysqlFieldWithFlags(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types, flags: c_uint) C.struct_st_mysql_field {
    var field: C.struct_st_mysql_field = std.mem.zeroes(C.struct_st_mysql_field);
    field.name = @constCast(name);
    field.length = @intCast(max_length);
    field.max_length = @intCast(max_length);
    field.name_length = @intCast(std.mem.len(name));
    field.flags = flags;
    field.type = kind;
    return field;
}

fn mysqlField(name: [*:0]const u8, max_length: usize, kind: C.enum_enum_field_types) C.struct_st_mysql_field {
    return mysqlFieldWithFlags(name, max_length, kind, C.NOT_NULL_FLAG);
}

const MysqlRowStorage1 = extern struct {
    values: [2][*c]u8,
    bytes: [5]u8,
    lengths: [1]c_ulong,
};

const MysqlRowStorage2 = extern struct {
    values: [3][*c]u8,
    bytes: [8]u8,
    lengths: [2]c_ulong,
};

// Test-only row fixtures. libmariadb's stored-result mysql_fetch_lengths()
// derives lengths from adjacent MYSQL_ROW value pointers, so these fixtures
// keep contiguous row bytes plus one extra end pointer. They must be initialized
// in place; returning them by value would leave value pointers aimed at a
// temporary copy.
fn initMysqlRowStorage1(storage: *MysqlRowStorage1, value: ?[]const u8) void {
    storage.* = .{
        .values = .{ null, null },
        .bytes = @splat(0),
        .lengths = .{0},
    };
    if (value) |bytes| {
        std.debug.assert(bytes.len + 1 <= storage.bytes.len);
        @memcpy(storage.bytes[0..bytes.len], bytes);
        storage.values[0] = &storage.bytes[0];
        storage.values[1] = &storage.bytes[bytes.len + 1];
    }
}

fn initMysqlRowStorage2(storage: *MysqlRowStorage2, value1: []const u8, value2: []const u8) void {
    storage.* = .{
        .values = .{ null, null, null },
        .bytes = @splat(0),
        .lengths = .{ 0, 0 },
    };
    const value2Offset = value1.len + 1;
    const endOffset = value2Offset + value2.len + 1;
    std.debug.assert(endOffset <= storage.bytes.len);
    @memcpy(storage.bytes[0..value1.len], value1);
    @memcpy(storage.bytes[value2Offset..][0..value2.len], value2);
    storage.values[0] = &storage.bytes[0];
    storage.values[1] = &storage.bytes[value2Offset];
    storage.values[2] = &storage.bytes[endOffset];
}

fn mysqlRow(storage: anytype, next: [*c]C.struct_st_mysql_rows) C.struct_st_mysql_rows {
    var row: C.struct_st_mysql_rows = std.mem.zeroes(C.struct_st_mysql_rows);
    row.next = next;
    row.data = &storage.values;
    var length: c_ulong = 0;
    for (storage.lengths) |field_length| {
        length += field_length;
    }
    row.length = length;
    return row;
}

fn mysqlData(first_row: [*c]C.struct_st_mysql_rows, row_count: usize, field_count: usize) C.struct_st_mysql_data {
    var data: C.struct_st_mysql_data = std.mem.zeroes(C.struct_st_mysql_data);
    data.data = first_row;
    data.rows = @intCast(row_count);
    data.fields = @intCast(field_count);
    return data;
}

fn mysqlResult(fields: []C.struct_st_mysql_field, data: *C.struct_st_mysql_data, lengths: [*c]c_ulong) C.struct_st_mysql_res {
    var result: C.struct_st_mysql_res = std.mem.zeroes(C.struct_st_mysql_res);
    result.row_count = data.rows;
    result.field_count = @intCast(fields.len);
    result.fields = fields.ptr;
    result.data = data;
    result.data_cursor = data.data;
    result.lengths = lengths;
    return result;
}

fn expectRendered(result: *C.struct_st_mysql_res, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_result(&writer.writer, result);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedVertical(result: *C.struct_st_mysql_res, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_result_vertical(&writer.writer, result);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedOk(ok: OKResult, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_ok(&writer.writer, ok);

    try std.testing.expectEqualStrings(expect, writer.written());
}

fn expectRenderedError(errno: u32, sqlstate: ?[]const u8, message: []const u8, expect: []const u8) !void {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var writer: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = writer.toArrayList();

    try render_error(&writer.writer, errno, sqlstate, message);

    try std.testing.expectEqualStrings(expect, writer.written());
}

test "render SQL error" {
    try expectRenderedError(1064, "42000", "You have an error in your SQL syntax",
        \\ERROR 1064 (42000): You have an error in your SQL syntax
        \\
    );
}

test "render query OK with affected rows" {
    try expectRenderedOk(.{
        .affected_rows = 2,
        .warnings = 0,
        .info = null,
    },
        \\Query OK, 2 rows affected
        \\
        \\
    );
}

test "render query OK singular affected row with warnings and info" {
    try expectRenderedOk(.{
        .affected_rows = 1,
        .warnings = 1,
        .info = "Rows matched: 1  Changed: 1  Warnings: 1",
    },
        \\Query OK, 1 row affected, 1 warning
        \\Rows matched: 1  Changed: 1  Warnings: 1
        \\
        \\
    );
}

test "render empty result set" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_LONG),
    };
    var data = mysqlData(null, 0, fields.len);
    var lengths = [_]c_ulong{0};
    var result = mysqlResult(&fields, &data, &lengths);

    const expect =
        \\Empty set
        \\
        \\
    ;
    try expectRendered(&result, expect);
}

test "render SELECT 1" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\+---+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render SELECT 1 AS one" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("one", 1, C.MYSQL_TYPE_LONG),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "1");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+-----+
        \\| one |
        \\+-----+
        \\|   1 |
        \\+-----+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render SELECT 1 AS one, 'two' AS two vertically" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("one", 1, C.MYSQL_TYPE_LONG),
        mysqlField("two", 3, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage2 = undefined;
    initMysqlRowStorage2(&row_storage, "1", "two");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\*************************** 1. row ***************************
        \\one: 1
        \\two: two
        \\
    ;
    try expectRenderedVertical(&result, expect);
}

test "render SELECT 'one' AS '1'" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "one");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+-----+
        \\| 1   |
        \\+-----+
        \\| one |
        \\+-----+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render string cells left aligned" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("word", 1, C.MYSQL_TYPE_VAR_STRING),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, "x");
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| word |
        \\+------+
        \\| x    |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render nullable column leaves room for NULL" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlFieldWithFlags("n", 0, C.MYSQL_TYPE_VAR_STRING, 0),
    };
    var row_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row_storage, null);
    var row = mysqlRow(&row_storage, null);
    var data = mysqlData(&row, 1, fields.len);
    var result = mysqlResult(&fields, &data, &row_storage.lengths);

    const expect =
        \\+------+
        \\| n    |
        \\+------+
        \\| NULL |
        \\+------+
        \\
    ;
    try expectRendered(&result, expect);
}

test "render multiple rows with one bottom border" {
    var fields = [_]C.struct_st_mysql_field{
        mysqlField("1", 1, C.MYSQL_TYPE_LONG),
    };
    var row2_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row2_storage, "2");
    var row1_storage: MysqlRowStorage1 = undefined;
    initMysqlRowStorage1(&row1_storage, "1");
    var row2 = mysqlRow(&row2_storage, null);
    var row1 = mysqlRow(&row1_storage, &row2);
    var data = mysqlData(&row1, 2, fields.len);
    var result = mysqlResult(&fields, &data, &row1_storage.lengths);

    const expect =
        \\+---+
        \\| 1 |
        \\+---+
        \\| 1 |
        \\| 2 |
        \\+---+
        \\
    ;
    try expectRendered(&result, expect);
}
