const std = @import("std");

const C = @import("mysql_c");
const Mysql = @import("mysql.zig");

/// How a result value is written by the structured formats (JSON and CSV).
pub const Kind = enum { null, number, decimal, json, binary, text };

/// Classifies one fetched value from its column type and charset. A NULL value
/// is always `.null`. Binary data is a string-like type with the binary charset
/// (63), as the server reports BINARY, VARBINARY and BLOB columns.
pub fn classify(field: *const C.struct_st_mysql_field, value: ?[]const u8) Kind {
    if (value == null) {
        return .null;
    }
    return switch (field.type) {
        C.MYSQL_TYPE_TINY,
        C.MYSQL_TYPE_SHORT,
        C.MYSQL_TYPE_INT24,
        C.MYSQL_TYPE_LONG,
        C.MYSQL_TYPE_LONGLONG,
        C.MYSQL_TYPE_YEAR,
        C.MYSQL_TYPE_FLOAT,
        C.MYSQL_TYPE_DOUBLE,
        => .number,
        C.MYSQL_TYPE_DECIMAL,
        C.MYSQL_TYPE_NEWDECIMAL,
        => .decimal,
        C.MYSQL_TYPE_JSON => .json,
        else => if (isBinaryType(field)) .binary else .text,
    };
}

fn isBinaryType(field: *const C.struct_st_mysql_field) bool {
    if (field.charsetnr != 63) {
        return false;
    }
    return switch (field.type) {
        C.MYSQL_TYPE_BIT,
        C.MYSQL_TYPE_TINY_BLOB,
        C.MYSQL_TYPE_MEDIUM_BLOB,
        C.MYSQL_TYPE_LONG_BLOB,
        C.MYSQL_TYPE_BLOB,
        C.MYSQL_TYPE_VARCHAR,
        C.MYSQL_TYPE_VAR_STRING,
        C.MYSQL_TYPE_STRING,
        C.MYSQL_TYPE_GEOMETRY,
        => true,
        else => false,
    };
}

/// Writes `bytes` as standard base64 with padding (RFC 4648), without line breaks.
pub fn writeBase64(out: *std.Io.Writer, bytes: []const u8) !void {
    try std.base64.standard.Encoder.encodeWriter(out, bytes);
}

test "classify maps numeric types to number" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("tiny", 0, C.MYSQL_TYPE_TINY),
        Mysql.mysqlField("big", 0, C.MYSQL_TYPE_LONGLONG),
        Mysql.mysqlField("year", 0, C.MYSQL_TYPE_YEAR),
        Mysql.mysqlField("dbl", 0, C.MYSQL_TYPE_DOUBLE),
    };
    for (&fields) |*field| {
        try std.testing.expectEqual(Kind.number, classify(field, "1"));
    }
}

test "classify maps DECIMAL to decimal and JSON to json" {
    const decimal = Mysql.mysqlField("dec", 0, C.MYSQL_TYPE_NEWDECIMAL);
    try std.testing.expectEqual(Kind.decimal, classify(&decimal, "12.30"));
    const json = Mysql.mysqlField("doc", 0, C.MYSQL_TYPE_JSON);
    try std.testing.expectEqual(Kind.json, classify(&json, "{}"));
}

test "classify maps binary charset string types to binary" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlBinaryField("bits", 0, C.MYSQL_TYPE_BIT),
        Mysql.mysqlBinaryField("blob", 0, C.MYSQL_TYPE_BLOB),
        Mysql.mysqlBinaryField("tiny", 0, C.MYSQL_TYPE_TINY_BLOB),
        Mysql.mysqlBinaryField("bin", 0, C.MYSQL_TYPE_STRING),
        Mysql.mysqlBinaryField("varbin", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlBinaryField("geo", 0, C.MYSQL_TYPE_GEOMETRY),
    };
    for (&fields) |*field| {
        try std.testing.expectEqual(Kind.binary, classify(field, "x"));
    }
}

test "classify keeps text columns with a text charset as text" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("day", 0, C.MYSQL_TYPE_DATE),
        Mysql.mysqlField("txt", 0, C.MYSQL_TYPE_BLOB),
        Mysql.mysqlField("enum", 0, C.MYSQL_TYPE_STRING),
        Mysql.mysqlField("set", 0, C.MYSQL_TYPE_VARCHAR),
    };
    for (&fields) |*field| {
        try std.testing.expectEqual(Kind.text, classify(field, "x"));
    }
}

test "classify reports NULL for any type" {
    const field = Mysql.mysqlBinaryField("blob", 0, C.MYSQL_TYPE_BLOB);
    try std.testing.expectEqual(Kind.null, classify(&field, null));
    const number = Mysql.mysqlField("n", 0, C.MYSQL_TYPE_LONG);
    try std.testing.expectEqual(Kind.null, classify(&number, null));
}

test "writeBase64 pads to a multiple of four characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeBase64(&writer.writer, "");
    try writeBase64(&writer.writer, "f");
    try writeBase64(&writer.writer, "fo");
    try writeBase64(&writer.writer, "foo");
    try writeBase64(&writer.writer, "\x00\xff");
    try std.testing.expectEqualStrings("Zg==Zm8=Zm9vAP8=", writer.written());
}

test "writeBase64 encodes the RFC 4648 vectors" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeBase64(&writer.writer, "foobar");
    try std.testing.expectEqualStrings("Zm9vYmFy", writer.written());
}

