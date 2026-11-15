const std = @import("std");

const C = @import("mysql_c");
const ResultValue = @import("result_value.zig");
const Mysql = @import("mysql.zig");

/// Writes one field value, RFC 4180 style. NULL is an empty field with nothing
/// between the commas, and an empty string is `""`, as PostgreSQL's `COPY ... CSV`
/// writes them. Binary data is base64, which never needs quoting. Any other value is
/// quoted only when it needs it. Bytes that aren't valid UTF-8 are written unchanged.
pub fn writeField(out: *std.Io.Writer, field: *const C.struct_st_mysql_field, value: ?[]const u8) !void {
    const kind = ResultValue.classify(field, value);
    if (kind == .null) {
        return;
    }
    const bytes = value.?;
    if (kind == .binary and bytes.len > 0) {
        try ResultValue.writeBase64(out, bytes);
        return;
    }
    try writeText(out, bytes);
}

/// Writes the column names as one line, quoted as needed, with duplicate names
/// written as they are. Callers that omit the header (`-N`) don't call this.
pub fn writeHeader(out: *std.Io.Writer, fields: []const C.struct_st_mysql_field) !void {
    for (fields, 0..) |*field, i| {
        if (i > 0) {
            try out.writeByte(',');
        }
        try writeText(out, fieldName(field));
    }
    try out.writeByte('\n');
}

/// Writes one row as one line, `\n` included. `row` and `lengths` are as
/// `mysql_fetch_row` and `mysql_fetch_lengths` return them, with one entry per field.
pub fn writeRow(
    out: *std.Io.Writer,
    fields: []const C.struct_st_mysql_field,
    row: C.MYSQL_ROW,
    lengths: [*c]c_ulong,
) !void {
    for (fields, 0..) |*field, i| {
        if (i > 0) {
            try out.writeByte(',');
        }
        const value: ?[]const u8 = if (row[i] == null) null else row[i][0..lengths[i]];
        try writeField(out, field, value);
    }
    try out.writeByte('\n');
}

/// Writes text as a CSV field, quoted when `needsQuotes` says so. Inside quotes each `"` is doubled.
fn writeText(out: *std.Io.Writer, bytes: []const u8) !void {
    if (!needsQuotes(bytes)) {
        try out.writeAll(bytes);
        return;
    }
    try out.writeByte('"');
    for (bytes) |byte| {
        if (byte == '"') {
            try out.writeByte('"');
        }
        try out.writeByte(byte);
    }
    try out.writeByte('"');
}

/// An empty field, a field with a comma, quote, CR or LF, or a field with a leading or trailing space.
fn needsQuotes(bytes: []const u8) bool {
    if (bytes.len == 0) {
        return true;
    }
    if (bytes[0] == ' ' or bytes[bytes.len - 1] == ' ') {
        return true;
    }
    return std.mem.indexOfAny(u8, bytes, ",\"\r\n") != null;
}

fn fieldName(field: *const C.struct_st_mysql_field) []const u8 {
    return field.name[0..field.name_length];
}

fn expectField(field: *const C.struct_st_mysql_field, value: ?[]const u8, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeField(&writer.writer, field, value);
    try std.testing.expectEqualStrings(expected, writer.written());
}

test "writeField quotes a field with a comma, quote, CR or LF, doubling quotes" {
    const text = Mysql.mysqlField("t", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectField(&text, "a,b", "\"a,b\"");
    try expectField(&text, "say \"hi\"", "\"say \"\"hi\"\"\"");
    try expectField(&text, "x\ry", "\"x\ry\"");
    try expectField(&text, "x\ny", "\"x\ny\"");
    try expectField(&text, "\"", "\"\"\"\"");
}

test "writeField quotes leading and trailing spaces but not inner ones" {
    const text = Mysql.mysqlField("t", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectField(&text, " a", "\" a\"");
    try expectField(&text, "a ", "\"a \"");
    try expectField(&text, " ", "\" \"");
    try expectField(&text, "a b", "a b");
}

test "writeField leaves tabs and backslashes unquoted" {
    const text = Mysql.mysqlField("t", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectField(&text, "a\tb", "a\tb");
    try expectField(&text, "a\\nb", "a\\nb");
}

test "writeField writes NULL as nothing and an empty string as quotes" {
    const text = Mysql.mysqlField("t", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectField(&text, null, "");
    try expectField(&text, "", "\"\"");
    const long = Mysql.mysqlField("n", 0, C.MYSQL_TYPE_LONG);
    try expectField(&long, null, "");
    const blob = Mysql.mysqlBinaryField("b", 0, C.MYSQL_TYPE_BLOB);
    try expectField(&blob, null, "");
    try expectField(&blob, "", "\"\"");
}

test "writeField writes numbers and decimals unquoted" {
    const big = Mysql.mysqlField("big", 0, C.MYSQL_TYPE_LONGLONG);
    try expectField(&big, "-7", "-7");
    try expectField(&big, "18446744073709551615", "18446744073709551615");
    const decimal = Mysql.mysqlField("dec", 0, C.MYSQL_TYPE_NEWDECIMAL);
    try expectField(&decimal, "12.30", "12.30");
    const double = Mysql.mysqlField("d", 0, C.MYSQL_TYPE_DOUBLE);
    try expectField(&double, "1.5e10", "1.5e10");
}

test "writeField keeps the server's leading zeros" {
    const padded = Mysql.mysqlField("padded", 0, C.MYSQL_TYPE_LONG);
    try expectField(&padded, "00042", "00042");
    const year = Mysql.mysqlField("y", 0, C.MYSQL_TYPE_YEAR);
    try expectField(&year, "0000", "0000");
}

test "writeField writes binary data as base64 without quotes" {
    const blob = Mysql.mysqlBinaryField("blob", 0, C.MYSQL_TYPE_BLOB);
    try expectField(&blob, "\x00\xff", "AP8=");
    try expectField(&blob, "f", "Zg==");
    try expectField(&blob, "foo", "Zm9v");
}

test "writeField quotes a JSON column when its text needs it" {
    const doc = Mysql.mysqlField("doc", 0, C.MYSQL_TYPE_JSON);
    try expectField(&doc, "{\"a\": [1, \"b\"]}", "\"{\"\"a\"\": [1, \"\"b\"\"]}\"");
    try expectField(&doc, "[1]", "[1]");
}

test "writeField writes invalid UTF-8 bytes unchanged" {
    const text = Mysql.mysqlField("t", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectField(&text, "a\x80b", "a\x80b");
}

test "writeHeader writes the names on one line and keeps duplicates" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("id", 0, C.MYSQL_TYPE_LONG),
        Mysql.mysqlField("a,b", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlField("a,b", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeHeader(&writer.writer, &fields);
    try std.testing.expectEqualStrings("id,\"a,b\",\"a,b\"\n", writer.written());
}

test "writeRow writes one line with NULL, empty strings and quoted fields" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("id", 0, C.MYSQL_TYPE_LONGLONG),
        Mysql.mysqlField("name", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlField("note", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlField("gone", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlField("amount", 0, C.MYSQL_TYPE_NEWDECIMAL),
        Mysql.mysqlBinaryField("data", 0, C.MYSQL_TYPE_BLOB),
    };
    var id = "2".*;
    var name = "grace, rear admiral".*;
    var note = "".*;
    var amount = "2.50".*;
    var data = "f".*;
    var row = [_][*c]u8{ &id, &name, &note, null, &amount, &data };
    var lengths = [_]c_ulong{ 1, 19, 0, 0, 4, 1 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeRow(&writer.writer, &fields, &row, &lengths);
    try std.testing.expectEqualStrings("2,\"grace, rear admiral\",\"\",,2.50,Zg==\n", writer.written());
}

test "writeRow without writeHeader writes no header line" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("id", 0, C.MYSQL_TYPE_LONG),
    };
    var id = "1".*;
    var row = [_][*c]u8{&id};
    var lengths = [_]c_ulong{1};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeRow(&writer.writer, &fields, &row, &lengths);
    try std.testing.expectEqualStrings("1\n", writer.written());
}
