const std = @import("std");
const Allocator = std.mem.Allocator;

const C = @import("mysql_c");
const ResultValue = @import("result_value.zig");
const Mysql = @import("mysql.zig");

/// Written in place of each byte that isn't valid UTF-8.
const replacement = "\u{fffd}";

/// Writes `bytes` as a JSON string, quotes included. Bytes that aren't valid
/// UTF-8 each become U+FFFD.
pub fn writeString(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];
        if (byte < 0x80) {
            try writeAsciiByte(out, byte);
            i += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try out.writeAll(replacement);
            i += 1;
            continue;
        };
        if (i + sequence_len > bytes.len) {
            try out.writeAll(replacement);
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(bytes[i..][0..sequence_len]) catch {
            try out.writeAll(replacement);
            i += 1;
            continue;
        };
        try out.writeAll(bytes[i..][0..sequence_len]);
        i += sequence_len;
    }
    try out.writeByte('"');
}

fn writeAsciiByte(out: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        0x08 => try out.writeAll("\\b"),
        0x0c => try out.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try out.print("\\u{x:0>4}", .{byte}),
        else => try out.writeByte(byte),
    }
}

/// Writes one field value as a JSON value. NULL is `null`; integers and floats
/// are the server's text unchanged; DECIMAL is a string so its precision survives;
/// JSON columns are embedded as they are; binary data is base64.
pub fn writeValue(out: *std.Io.Writer, field: *const C.struct_st_mysql_field, value: ?[]const u8) !void {
    const kind = ResultValue.classify(field, value);
    if (kind == .null) {
        try out.writeAll("null");
        return;
    }
    const bytes = value.?;
    switch (kind) {
        .null => unreachable,
        .number, .json => try out.writeAll(bytes),
        .decimal, .text => try writeString(out, bytes),
        .binary => {
            try out.writeByte('"');
            try ResultValue.writeBase64(out, bytes);
            try out.writeByte('"');
        },
    }
}

/// JSON object keys for a result set. `renamed` counts the columns whose name
/// repeated an earlier one and got a suffix.
pub const ColumnKeys = struct {
    names: [][]u8,
    renamed: usize,

    pub fn deinit(self: ColumnKeys, allocator: Allocator) void {
        freeNames(allocator, self.names);
    }
};

/// Column names as JSON keys. A name that repeats an earlier key gets `_2`, `_3`
/// and so on, skipping any name the result already uses, so no key repeats.
/// Names are compared exactly, as JSON keys are.
pub fn columnKeys(allocator: Allocator, fields: []const C.struct_st_mysql_field) !ColumnKeys {
    const names = try allocator.alloc([]u8, fields.len);
    var count: usize = 0;
    errdefer freeNames(allocator, names[0..count]);

    var renamed: usize = 0;
    for (fields, 0..) |*field, i| {
        const name = fieldName(field);
        if (containsName(names[0..i], name)) {
            names[i] = try uniqueSuffixed(allocator, fields, names[0..i], name);
            renamed += 1;
        } else {
            names[i] = try allocator.dupe(u8, name);
        }
        count = i + 1;
    }
    return .{ .names = names, .renamed = renamed };
}

/// The first `name_2`, `name_3`, ... that matches no field name and no key so far.
fn uniqueSuffixed(allocator: Allocator, fields: []const C.struct_st_mysql_field, keys: []const []u8, name: []const u8) ![]u8 {
    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ name, suffix });
        var taken = containsName(keys, candidate);
        for (fields) |*field| {
            if (std.mem.eql(u8, fieldName(field), candidate)) {
                taken = true;
            }
        }
        if (!taken) {
            return candidate;
        }
        allocator.free(candidate);
    }
}

fn fieldName(field: *const C.struct_st_mysql_field) []const u8 {
    return field.name[0..field.name_length];
}

fn containsName(names: []const []u8, name: []const u8) bool {
    for (names) |existing| {
        if (std.mem.eql(u8, existing, name)) {
            return true;
        }
    }
    return false;
}

fn freeNames(allocator: Allocator, names: [][]u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}

/// Writes one row as a JSON object, `{"key":value,...}`, with no newline.
/// `keys` comes from `columnKeys`, one per field.
pub fn writeRowObject(
    out: *std.Io.Writer,
    keys: []const []u8,
    fields: []const C.struct_st_mysql_field,
    row: C.MYSQL_ROW,
    lengths: [*c]c_ulong,
) !void {
    try out.writeByte('{');
    for (keys, 0..) |key, i| {
        if (i > 0) {
            try out.writeByte(',');
        }
        try writeString(out, key);
        try out.writeByte(':');
        const value: ?[]const u8 = if (row[i] == null) null else row[i][0..lengths[i]];
        try writeValue(out, &fields[i], value);
    }
    try out.writeByte('}');
}

fn expectValue(field: *const C.struct_st_mysql_field, value: ?[]const u8, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeValue(&writer.writer, field, value);
    try std.testing.expectEqualStrings(expected, writer.written());
}

test "writeString escapes quote, backslash and control characters" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeString(&writer.writer, "q\"b\\n\n\r\t\x08\x0c\x01\x1f\x7f");
    try std.testing.expectEqualStrings("\"q\\\"b\\\\n\\n\\r\\t\\b\\f\\u0001\\u001f\x7f\"", writer.written());
}

test "writeString writes empty strings and valid UTF-8 unchanged" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeString(&writer.writer, "");
    try writeString(&writer.writer, "é 漢 🙂");
    try std.testing.expectEqualStrings("\"\"\"é 漢 🙂\"", writer.written());
}

test "writeString replaces invalid UTF-8 bytes with U+FFFD" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    // A lone continuation byte, a truncated lead byte before ASCII, and a UTF-8 surrogate.
    try writeString(&writer.writer, "a\x80b\xe4Ac\xed\xa0\x80");
    try std.testing.expectEqualStrings("\"a\u{fffd}b\u{fffd}Ac\u{fffd}\u{fffd}\u{fffd}\"", writer.written());
}

test "writeValue writes NULL as null and empty text as an empty string" {
    const text = Mysql.mysqlField("txt", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectValue(&text, null, "null");
    try expectValue(&text, "", "\"\"");
}

test "writeValue writes integers and floats as the server's text" {
    const long = Mysql.mysqlField("n", 0, C.MYSQL_TYPE_LONG);
    try expectValue(&long, "-7", "-7");
    const year = Mysql.mysqlField("y", 0, C.MYSQL_TYPE_YEAR);
    try expectValue(&year, "2026", "2026");
    const double = Mysql.mysqlField("d", 0, C.MYSQL_TYPE_DOUBLE);
    try expectValue(&double, "1.5e10", "1.5e10");
    const float = Mysql.mysqlField("f", 0, C.MYSQL_TYPE_FLOAT);
    try expectValue(&float, "0.25", "0.25");
}

test "writeValue keeps BIGINT UNSIGNED max exact" {
    const big = Mysql.mysqlField("big", 0, C.MYSQL_TYPE_LONGLONG);
    try expectValue(&big, "18446744073709551615", "18446744073709551615");
}

test "writeValue writes DECIMAL as a string" {
    const decimal = Mysql.mysqlField("dec", 0, C.MYSQL_TYPE_NEWDECIMAL);
    try expectValue(&decimal, "12.30", "\"12.30\"");
    try expectValue(&decimal, "-0.00", "\"-0.00\"");
}

test "writeValue embeds JSON columns as raw JSON" {
    const doc = Mysql.mysqlField("doc", 0, C.MYSQL_TYPE_JSON);
    try expectValue(&doc, "{\"a\": [1, \"b\"]}", "{\"a\": [1, \"b\"]}");
}

test "writeValue writes binary data as padded base64" {
    const blob = Mysql.mysqlBinaryField("blob", 0, C.MYSQL_TYPE_BLOB);
    try expectValue(&blob, "\x00\xff", "\"AP8=\"");
    try expectValue(&blob, "f", "\"Zg==\"");
    try expectValue(&blob, "foo", "\"Zm9v\"");
    const varbin = Mysql.mysqlBinaryField("vb", 0, C.MYSQL_TYPE_VAR_STRING);
    try expectValue(&varbin, "ab", "\"YWI=\"");
}

test "writeValue writes dates, enums and text as escaped strings" {
    const day = Mysql.mysqlField("day", 0, C.MYSQL_TYPE_DATE);
    try expectValue(&day, "2026-11-14", "\"2026-11-14\"");
    const stamp = Mysql.mysqlField("ts", 0, C.MYSQL_TYPE_TIMESTAMP);
    try expectValue(&stamp, "2026-11-14 10:00:00", "\"2026-11-14 10:00:00\"");
    const enumerated = Mysql.mysqlField("e", 0, C.MYSQL_TYPE_STRING);
    try expectValue(&enumerated, "a\"b", "\"a\\\"b\"");
    const txt = Mysql.mysqlField("t", 0, C.MYSQL_TYPE_BLOB);
    try expectValue(&txt, "line\nnext", "\"line\\nnext\"");
}

test "columnKeys keeps unique names and reports no renames" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("id", 0, C.MYSQL_TYPE_LONG),
        Mysql.mysqlField("name", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlField("Name", 0, C.MYSQL_TYPE_VAR_STRING),
    };
    const keys = try columnKeys(std.testing.allocator, &fields);
    defer keys.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), keys.renamed);
    try std.testing.expectEqualStrings("id", keys.names[0]);
    try std.testing.expectEqualStrings("name", keys.names[1]);
    try std.testing.expectEqualStrings("Name", keys.names[2]);
}

test "columnKeys suffixes repeated names" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_LONG),
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_LONG),
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_LONG),
    };
    const keys = try columnKeys(std.testing.allocator, &fields);
    defer keys.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), keys.renamed);
    try std.testing.expectEqualStrings("a", keys.names[0]);
    try std.testing.expectEqualStrings("a_2", keys.names[1]);
    try std.testing.expectEqualStrings("a_3", keys.names[2]);
}

test "columnKeys skips a suffix that another column already has" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_LONG),
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_LONG),
        Mysql.mysqlField("a_2", 0, C.MYSQL_TYPE_LONG),
    };
    const keys = try columnKeys(std.testing.allocator, &fields);
    defer keys.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a", keys.names[0]);
    try std.testing.expectEqualStrings("a_3", keys.names[1]);
    try std.testing.expectEqualStrings("a_2", keys.names[2]);
}

test "writeRowObject writes one object with NULL and escaped keys" {
    var fields = [_]C.struct_st_mysql_field{
        Mysql.mysqlField("id", 0, C.MYSQL_TYPE_LONGLONG),
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_VAR_STRING),
        Mysql.mysqlField("a", 0, C.MYSQL_TYPE_NEWDECIMAL),
        Mysql.mysqlBinaryField("b", 0, C.MYSQL_TYPE_BLOB),
        Mysql.mysqlField("n", 0, C.MYSQL_TYPE_LONG),
    };
    const keys = try columnKeys(std.testing.allocator, &fields);
    defer keys.deinit(std.testing.allocator);

    var id = "1".*;
    var text = "x\"y".*;
    var decimal = "2.50".*;
    var blob = "f".*;
    var row = [_][*c]u8{ &id, &text, &decimal, &blob, null };
    var lengths = [_]c_ulong{ 1, 3, 4, 1, 0 };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var writer: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer buf = writer.toArrayList();

    try writeRowObject(&writer.writer, keys.names, &fields, &row, &lengths);
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"a\":\"x\\\"y\",\"a_2\":\"2.50\",\"b\":\"Zg==\",\"n\":null}",
        writer.written(),
    );
}
