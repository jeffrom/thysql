//! Query plans, read from the result of an EXPLAIN statement in any of the formats that MySQL and
//! MariaDB give: the traditional table, the tree text of FORMAT=TREE and EXPLAIN ANALYZE, and
//! FORMAT=JSON (MySQL's version 1, and version 2 of `explain_json_format_version`). Each becomes
//! a list of operations, so that `plan_labels.zig` can put them on the statement the same way.
//!
//! The tree formats give a tree of operations; the traditional table and JSON version 1 give one
//! table access per row or `table` object, with sorts and temporary tables as flags.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    /// Reads a table: a scan, an index lookup, a range scan.
    access,
    /// `Filter: (condition)`, over its child.
    filter,
    sort,
    /// `Aggregate using temporary table`, or "Using temporary".
    temp_aggregate,
    /// `Group aggregate`: grouped in index order, without a temporary table.
    group_aggregate,
    /// `Aggregate:` without GROUP BY.
    aggregate,
    /// `Temporary table with deduplication`, or JSON's duplicates_removal.
    dedup,
    limit,
    join,
    /// `Hash`: the build side of a hash join.
    hash,
    /// `Materialize`: a derived table or CTE written to a temporary table.
    materialize,
    other,
};

pub const Op = struct {
    kind: Kind = .other,
    /// The operation as the plan names it, such as `Table scan on o`.
    text: []const u8 = "",
    parent: ?u32 = null,
    /// Rows per loop, as the optimizer estimates them.
    est_rows: ?f64 = null,
    /// Rows per loop, as EXPLAIN ANALYZE counted them.
    actual_rows: ?f64 = null,
    loops: ?f64 = null,
    /// Milliseconds to the last row, per loop.
    last_row_ms: ?f64 = null,
    never_executed: bool = false,

    // For an access.
    /// The table as the plan names it: its alias when it has one.
    table: ?[]const u8 = null,
    /// How it is read, such as "table scan" or "index lookup".
    method: []const u8 = "",
    key: ?[]const u8 = null,
    /// Every row of the table (or of the index) is read.
    full_scan: bool = false,
    /// Only the index is read.
    covering: bool = false,
    /// The condition checked on the rows: a filter's, or JSON's attached_condition.
    condition: ?[]const u8 = null,
    /// "Using where": a condition is checked on the rows, but the plan does not say which.
    has_condition: bool = false,
    /// The estimated percentage of rows that the condition keeps (traditional and JSON 1).
    filtered: ?f64 = null,
    /// The actual percentage (MariaDB's ANALYZE).
    actual_filtered: ?f64 = null,

    /// The total actual time, over all loops.
    pub fn totalMs(self: Op) ?f64 {
        const ms = self.last_row_ms orelse return null;
        return ms * (self.loops orelse 1);
    }
};

pub const Format = enum { traditional, tree, json };

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    ops: []Op = &.{},
    /// The plan has actual rows and times.
    analyzed: bool = false,
    format: Format,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The first child of op `index`.
    pub fn firstChild(self: *const Plan, index: u32) ?u32 {
        for (self.ops, 0..) |op, i| {
            if (op.parent == index) return @intCast(i);
        }
        return null;
    }
};

/// Reads the plan from an EXPLAIN result: its column names and its rows. Null when the result is
/// not a plan this knows, such as DESCRIBE's column list.
pub fn fromResult(gpa: Allocator, columns: []const []const u8, rows: []const []const ?[]const u8) Allocator.Error!?Plan {
    if (columnIndex(columns, "select_type") != null and columnIndex(columns, "table") != null) {
        return try fromTraditional(gpa, columns, rows);
    }
    if (columns.len != 1 or rows.len == 0) return null;
    const text = rows[0][0] orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "->")) return try fromTree(gpa, trimmed);
    if (std.mem.startsWith(u8, trimmed, "{")) return try fromJson(gpa, trimmed);
    return null;
}

fn columnIndex(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |column, i| {
        if (std.ascii.eqlIgnoreCase(column, name)) return i;
    }
    return null;
}

// --- The traditional table -------------------------------------------------------------------

fn fromTraditional(gpa: Allocator, columns: []const []const u8, rows: []const []const ?[]const u8) Allocator.Error!Plan {
    var plan: Plan = .{ .arena = .init(gpa), .format = .traditional };
    errdefer plan.arena.deinit();
    const arena = plan.arena.allocator();
    var ops: std.ArrayList(Op) = .empty;

    const table_col = columnIndex(columns, "table");
    const type_col = columnIndex(columns, "type");
    const key_col = columnIndex(columns, "key");
    const rows_col = columnIndex(columns, "rows");
    const filtered_col = columnIndex(columns, "filtered");
    const extra_col = columnIndex(columns, "Extra");
    const r_rows_col = columnIndex(columns, "r_rows");
    const r_filtered_col = columnIndex(columns, "r_filtered");

    for (rows) |row| {
        const cell = struct {
            fn get(r: []const ?[]const u8, col: ?usize) ?[]const u8 {
                const c = col orelse return null;
                if (c >= r.len) return null;
                return r[c];
            }
        }.get;
        const access_type = cell(row, type_col) orelse "";
        const extra = cell(row, extra_col) orelse "";
        var op: Op = .{
            .kind = .access,
            .text = try arena.dupe(u8, access_type),
            .table = if (cell(row, table_col)) |t| try arena.dupe(u8, t) else null,
            .key = if (cell(row, key_col)) |k| try arena.dupe(u8, k) else null,
            .est_rows = number(cell(row, rows_col)),
            .filtered = number(cell(row, filtered_col)),
            .actual_rows = number(cell(row, r_rows_col)),
            .actual_filtered = number(cell(row, r_filtered_col)),
            .has_condition = contains(extra, "Using where"),
            .covering = containsWord(extra, "Using index"),
        };
        op.method = accessMethod(access_type);
        op.full_scan = std.ascii.eqlIgnoreCase(access_type, "ALL") or std.ascii.eqlIgnoreCase(access_type, "index");
        if (op.actual_rows != null) plan.analyzed = true;
        try ops.append(arena, op);
        if (contains(extra, "Using temporary")) try ops.append(arena, .{ .kind = .temp_aggregate, .text = "Using temporary" });
        if (contains(extra, "Using filesort")) try ops.append(arena, .{ .kind = .sort, .text = "Using filesort" });
    }
    plan.ops = ops.items;
    return plan;
}

/// The traditional `type` as words.
fn accessMethod(access_type: []const u8) []const u8 {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "ALL", "full table scan" },
        .{ "index", "full index scan" },
        .{ "range", "range scan" },
        .{ "ref", "index lookup" },
        .{ "eq_ref", "unique index lookup" },
        .{ "ref_or_null", "index lookup (or NULL)" },
        .{ "index_merge", "index merge" },
        .{ "fulltext", "full-text search" },
        .{ "const", "read once (constant)" },
        .{ "system", "read once (one row)" },
        .{ "unique_subquery", "unique subquery lookup" },
        .{ "index_subquery", "index subquery lookup" },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(access_type, entry[0])) return entry[1];
    }
    return access_type;
}

// --- The tree text -----------------------------------------------------------------------------

fn fromTree(gpa: Allocator, text: []const u8) Allocator.Error!Plan {
    var plan: Plan = .{ .arena = .init(gpa), .format = .tree };
    errdefer plan.arena.deinit();
    const arena = plan.arena.allocator();
    var ops: std.ArrayList(Op) = .empty;

    // The ops that hold the current line, by depth.
    var stack: std.ArrayList(u32) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r");
        const body = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, body, "-> ")) continue;
        const depth = (line.len - body.len) / 4;
        var op = parseTreeLine(body[3..]);
        if (op.actual_rows != null) plan.analyzed = true;

        stack.shrinkRetainingCapacity(@min(depth, stack.items.len));
        op.parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;
        op.text = try arena.dupe(u8, op.text);
        if (op.table) |t| op.table = try arena.dupe(u8, t);
        if (op.key) |k| op.key = try arena.dupe(u8, k);
        if (op.condition) |c| op.condition = try arena.dupe(u8, c);
        if (op.method.len > 0) op.method = try lowerFirst(arena, op.method);
        try ops.append(arena, op);
        try stack.append(arena, @intCast(ops.items.len - 1));
    }
    plan.ops = ops.items;
    return plan;
}

/// One line of the tree, after its `-> `: `Table scan on o  (cost=2059 rows=20349) (actual
/// time=0.121..2.11 rows=20000 loops=1)`. The strings are slices of `line`.
fn parseTreeLine(line: []const u8) Op {
    var end = line.len;
    var op: Op = .{};

    if (std.mem.lastIndexOf(u8, line, "(actual time=")) |at| {
        end = @min(end, at);
        const group = line[at + "(actual time=".len ..];
        // A..B rows=R loops=L)
        if (std.mem.indexOf(u8, group, "..")) |dots| {
            const after = group[dots + 2 ..];
            const space = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
            op.last_row_ms = number(after[0..space]);
        }
        op.actual_rows = field(group, "rows=");
        op.loops = field(group, "loops=");
    }
    if (std.mem.lastIndexOf(u8, line, "(never executed)")) |at| {
        end = @min(end, at);
        op.never_executed = true;
    }
    if (std.mem.lastIndexOf(u8, line, "(cost=")) |at| {
        end = @min(end, at);
        op.est_rows = field(line[at..], "rows=");
    }
    op.text = std.mem.trimEnd(u8, line[0..end], " ");
    classify(&op);
    return op;
}

/// The number after `name` in `text`, up to a space or `)`.
fn field(text: []const u8, name: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, text, name) orelse return null;
    const rest = text[at + name.len ..];
    var len: usize = 0;
    while (len < rest.len and rest[len] != ' ' and rest[len] != ')') len += 1;
    return number(rest[0..len]);
}

/// Sets the kind and the access fields from the op's text, as the tree and JSON 2 name it.
fn classify(op: *Op) void {
    const text = op.text;
    if (std.mem.startsWith(u8, text, "Filter: ")) {
        op.kind = .filter;
        op.condition = text["Filter: ".len..];
    } else if (std.mem.startsWith(u8, text, "Sort")) {
        op.kind = .sort;
    } else if (std.mem.startsWith(u8, text, "Aggregate using temporary table")) {
        op.kind = .temp_aggregate;
    } else if (std.mem.startsWith(u8, text, "Group aggregate")) {
        op.kind = .group_aggregate;
    } else if (std.mem.startsWith(u8, text, "Aggregate")) {
        op.kind = .aggregate;
    } else if (std.mem.startsWith(u8, text, "Temporary table with deduplication")) {
        op.kind = .dedup;
    } else if (std.mem.startsWith(u8, text, "Limit")) {
        op.kind = .limit;
    } else if (std.mem.startsWith(u8, text, "Materialize")) {
        op.kind = .materialize;
    } else if (std.mem.eql(u8, text, "Hash")) {
        op.kind = .hash;
    } else if (contains(text, " join")) {
        op.kind = .join;
        if (std.mem.indexOfScalar(u8, text, '(')) |open| op.condition = text[open..];
    } else if (std.mem.indexOf(u8, text, " on ")) |on| {
        // `<method> on <table> [using <key>] [...]`, where the method is a scan, lookup or search.
        const method = text[0..on];
        if (!(std.mem.endsWith(u8, method, "scan") or std.mem.endsWith(u8, method, "lookup") or std.mem.endsWith(u8, method, "search"))) return;
        op.kind = .access;
        op.method = method;
        const rest = text[on + 4 ..];
        const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        op.table = std.mem.trim(u8, rest[0..name_end], "`");
        if (std.mem.indexOf(u8, rest, " using ")) |using| {
            const key = rest[using + 7 ..];
            const key_end = std.mem.indexOfAny(u8, key, " (") orelse key.len;
            op.key = std.mem.trim(u8, key[0..key_end], "`");
        }
        op.full_scan = std.mem.eql(u8, method, "Table scan") or std.mem.endsWith(u8, method, "ndex scan");
        op.covering = std.mem.startsWith(u8, method, "Covering");
    }
}

// --- JSON --------------------------------------------------------------------------------------

fn fromJson(gpa: Allocator, text: []const u8) Allocator.Error!?Plan {
    var plan: Plan = .{ .arena = .init(gpa), .format = .json };
    errdefer plan.arena.deinit();
    const arena = plan.arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            plan.arena.deinit();
            return null;
        },
    };
    if (root != .object) {
        plan.arena.deinit();
        return null;
    }
    var ops: std.ArrayList(Op) = .empty;
    if (root.object.get("query_block") != null) {
        try walkJson1(arena, root, &ops);
    } else if (root.object.get("operation") != null) {
        try walkJson2(arena, root.object, null, &ops, &plan.analyzed);
    }
    plan.ops = ops.items;
    return plan;
}

/// JSON version 1: every `table` object is an access, and the operations around them are flags.
fn walkJson1(arena: Allocator, value: std.json.Value, ops: *std.ArrayList(Op)) Allocator.Error!void {
    switch (value) {
        .object => |object| {
            if (object.get("ordering_operation")) |ordering| {
                if (flag(ordering, "using_filesort")) try ops.append(arena, .{ .kind = .sort, .text = "using_filesort" });
            }
            if (object.get("grouping_operation")) |grouping| {
                if (flag(grouping, "using_temporary_table")) try ops.append(arena, .{ .kind = .temp_aggregate, .text = "using_temporary_table" });
                if (flag(grouping, "using_filesort")) try ops.append(arena, .{ .kind = .sort, .text = "using_filesort" });
            }
            // MariaDB: a `filesort` object around the tables it sorts.
            if (object.get("filesort")) |filesort| {
                if (filesort == .object) try ops.append(arena, .{ .kind = .sort, .text = "filesort" });
            }
            if (object.get("duplicates_removal")) |removal| {
                if (flag(removal, "using_temporary_table")) try ops.append(arena, .{ .kind = .dedup, .text = "duplicates_removal" });
            }
            if (object.get("table")) |table| {
                if (table == .object) {
                    const t = table.object;
                    const access_type = string(t.get("access_type")) orelse "";
                    try ops.append(arena, .{
                        .kind = .access,
                        .text = access_type,
                        .table = string(t.get("table_name")),
                        .key = string(t.get("key")),
                        .method = accessMethod(access_type),
                        .full_scan = std.ascii.eqlIgnoreCase(access_type, "ALL") or std.ascii.eqlIgnoreCase(access_type, "index"),
                        .covering = flag(table, "using_index"),
                        // MySQL's rows_examined_per_scan is MariaDB's rows.
                        .est_rows = jsonNumber(t.get("rows_examined_per_scan") orelse t.get("rows")),
                        .filtered = jsonNumber(t.get("filtered")),
                        .condition = string(t.get("attached_condition")),
                        .has_condition = t.get("attached_condition") != null,
                    });
                }
            }
            var it = object.iterator();
            while (it.next()) |entry| try walkJson1(arena, entry.value_ptr.*, ops);
        },
        .array => |array| for (array.items) |item| try walkJson1(arena, item, ops),
        else => {},
    }
}

/// JSON version 2: a tree of operations, named as the tree text names them, with `inputs`.
fn walkJson2(arena: Allocator, object: std.json.ObjectMap, parent: ?u32, ops: *std.ArrayList(Op), analyzed: *bool) Allocator.Error!void {
    var op: Op = .{
        .text = string(object.get("operation")) orelse "",
        .parent = parent,
        .est_rows = jsonNumber(object.get("estimated_rows")),
        .actual_rows = jsonNumber(object.get("actual_rows")),
        .loops = jsonNumber(object.get("actual_loops")),
        .last_row_ms = jsonNumber(object.get("actual_last_row_ms")),
    };
    classify(&op);
    if (op.method.len > 0) op.method = try lowerFirst(arena, op.method);
    if (string(object.get("alias"))) |alias| op.table = alias;
    if (string(object.get("condition"))) |condition| op.condition = condition;
    if (op.actual_rows != null) analyzed.* = true;
    try ops.append(arena, op);
    const index: u32 = @intCast(ops.items.len - 1);
    const inputs = object.get("inputs") orelse return;
    if (inputs != .array) return;
    for (inputs.array.items) |input| {
        if (input == .object) try walkJson2(arena, input.object, index, ops, analyzed);
    }
}

fn flag(value: std.json.Value, name: []const u8) bool {
    if (value != .object) return false;
    const v = value.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn string(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonNumber(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| number(s),
        else => null,
    };
}

// --- Helpers -----------------------------------------------------------------------------------

fn number(text: ?[]const u8) ?f64 {
    const t = std.mem.trim(u8, text orelse return null, " ");
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

fn contains(text: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, text, needle) != null;
}

/// True when `needle` is in `text` and not followed by more of a word ("Using index", not
/// "Using index condition").
fn containsWord(text: []const u8, needle: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, needle)) |at| {
        const after = at + needle.len;
        if (after == text.len or text[after] == ';') return true;
        start = after;
    }
    return false;
}

fn lowerFirst(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (text.len == 0 or !std.ascii.isUpper(text[0])) return text;
    const out = try arena.dupe(u8, text);
    out[0] = std.ascii.toLower(out[0]);
    return out;
}

const testing = std.testing;

test "the tree text of EXPLAIN ANALYZE" {
    const text =
        \\-> Limit: 5 row(s)  (actual time=4.68..4.68 rows=5 loops=1)
        \\    -> Sort: t DESC, limit input to 5 row(s) per chunk  (actual time=4.68..4.68 rows=5 loops=1)
        \\        -> Nested loop inner join  (cost=2415 rows=1017) (actual time=0.128..4.12 rows=1990 loops=1)
        \\            -> Filter: ((o.`status` = 'open') and (o.user_id > 10))  (cost=2059 rows=1017) (actual time=0.124..3.03 rows=1990 loops=1)
        \\                -> Table scan on o  (cost=2059 rows=20349) (actual time=0.121..2.11 rows=20000 loops=1)
        \\            -> Single-row index lookup on u using PRIMARY (id=o.user_id)  (cost=0.25 rows=1) (actual time=427e-6..446e-6 rows=1 loops=1990)
        \\            -> Filter: (x)  (cost=0.35 rows=1) (never executed)
    ;
    var plan = (try fromResult(testing.allocator, &.{"EXPLAIN"}, &.{&.{text}})).?;
    defer plan.deinit();
    try testing.expect(plan.analyzed);
    try testing.expectEqual(@as(usize, 7), plan.ops.len);
    const ops = plan.ops;
    try testing.expectEqual(Kind.limit, ops[0].kind);
    try testing.expectEqual(Kind.sort, ops[1].kind);
    try testing.expectEqual(@as(?u32, 0), ops[1].parent);
    try testing.expectEqual(Kind.filter, ops[3].kind);
    try testing.expectEqualStrings("((o.`status` = 'open') and (o.user_id > 10))", ops[3].condition.?);
    try testing.expectEqual(@as(?f64, 1017), ops[3].est_rows);
    try testing.expectEqual(@as(?f64, 1990), ops[3].actual_rows);

    const scan = ops[4];
    try testing.expectEqual(Kind.access, scan.kind);
    try testing.expectEqual(@as(?u32, 3), scan.parent);
    try testing.expectEqualStrings("o", scan.table.?);
    try testing.expectEqualStrings("table scan", scan.method);
    try testing.expect(scan.full_scan);
    try testing.expectEqual(@as(?f64, 20349), scan.est_rows);
    try testing.expectEqual(@as(?f64, 2.11), scan.last_row_ms);

    const lookup = ops[5];
    try testing.expectEqual(@as(?u32, 2), lookup.parent);
    try testing.expectEqualStrings("u", lookup.table.?);
    try testing.expectEqualStrings("PRIMARY", lookup.key.?);
    try testing.expectEqualStrings("single-row index lookup", lookup.method);
    try testing.expect(!lookup.full_scan);
    try testing.expectEqual(@as(?f64, 1990), lookup.loops);
    try testing.expectApproxEqAbs(@as(f64, 446e-6 * 1990), lookup.totalMs().?, 1e-9);
    try testing.expect(ops[6].never_executed);
}

test "the traditional table, with MySQL's and MariaDB's columns" {
    const columns = [_][]const u8{ "id", "select_type", "table", "partitions", "type", "possible_keys", "key", "key_len", "ref", "rows", "filtered", "Extra" };
    const rows = [_][]const ?[]const u8{
        &.{ "1", "SIMPLE", "o", null, "ALL", null, null, null, null, "20349", "10.00", "Using where; Using temporary; Using filesort" },
        &.{ "1", "SIMPLE", "u", null, "eq_ref", "PRIMARY", "PRIMARY", "4", "o.user_id", "1", "100.00", "Using index" },
    };
    var plan = (try fromResult(testing.allocator, &columns, &rows)).?;
    defer plan.deinit();
    try testing.expect(!plan.analyzed);
    try testing.expectEqual(@as(usize, 4), plan.ops.len);
    try testing.expectEqualStrings("full table scan", plan.ops[0].method);
    try testing.expect(plan.ops[0].full_scan and plan.ops[0].has_condition);
    try testing.expectEqual(@as(?f64, 10), plan.ops[0].filtered);
    try testing.expectEqual(Kind.temp_aggregate, plan.ops[1].kind);
    try testing.expectEqual(Kind.sort, plan.ops[2].kind);
    try testing.expectEqualStrings("unique index lookup", plan.ops[3].method);
    try testing.expect(plan.ops[3].covering);

    const maria = [_][]const u8{ "id", "select_type", "table", "type", "possible_keys", "key", "key_len", "ref", "rows", "r_rows", "filtered", "r_filtered", "Extra" };
    const maria_rows = [_][]const ?[]const u8{&.{ "1", "SIMPLE", "t", "ALL", null, null, null, null, "100", "1000.00", "100.00", "5.00", "Using where" }};
    var analyzed = (try fromResult(testing.allocator, &maria, &maria_rows)).?;
    defer analyzed.deinit();
    try testing.expect(analyzed.analyzed);
    try testing.expectEqual(@as(?f64, 1000), analyzed.ops[0].actual_rows);
    try testing.expectEqual(@as(?f64, 5), analyzed.ops[0].actual_filtered);
}

test "JSON version 1 and version 2" {
    const v1 =
        \\{"query_block": {"select_id": 1, "ordering_operation": {"using_filesort": true,
        \\  "table": {"table_name": "orders", "access_type": "ALL", "rows_examined_per_scan": 20349,
        \\    "filtered": "10.00", "attached_condition": "(`db`.`orders`.`status` = 'open')"}}}}
    ;
    var p1 = (try fromResult(testing.allocator, &.{"EXPLAIN"}, &.{&.{v1}})).?;
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 2), p1.ops.len);
    try testing.expectEqual(Kind.sort, p1.ops[0].kind);
    try testing.expectEqualStrings("orders", p1.ops[1].table.?);
    try testing.expectEqual(@as(?f64, 20349), p1.ops[1].est_rows);
    try testing.expectEqual(@as(?f64, 10), p1.ops[1].filtered);
    try testing.expectEqualStrings("(`db`.`orders`.`status` = 'open')", p1.ops[1].condition.?);

    const v2 =
        \\{"operation": "Filter: (o.`status` = 'open')", "condition": "(o.`status` = 'open')",
        \\ "estimated_rows": 2034.9, "actual_rows": 2000.0, "actual_loops": 1, "actual_last_row_ms": 2.91,
        \\ "inputs": [{"alias": "o", "operation": "Table scan on o", "table_name": "orders",
        \\   "estimated_rows": 20349.0, "actual_rows": 20000.0, "actual_loops": 1, "actual_last_row_ms": 2.1}]}
    ;
    var p2 = (try fromResult(testing.allocator, &.{"EXPLAIN"}, &.{&.{v2}})).?;
    defer p2.deinit();
    try testing.expect(p2.analyzed);
    try testing.expectEqual(@as(usize, 2), p2.ops.len);
    try testing.expectEqual(Kind.filter, p2.ops[0].kind);
    try testing.expectEqual(Kind.access, p2.ops[1].kind);
    try testing.expectEqual(@as(?u32, 0), p2.ops[1].parent);
    try testing.expectEqualStrings("o", p2.ops[1].table.?);
    try testing.expectEqualStrings("table scan", p2.ops[1].method);
}

test "MariaDB's JSON" {
    const text =
        \\{"query_block": {"select_id": 1, "nested_loop": [{"read_sorted_file": {"filesort": {"sort_key": "orders.created_at",
        \\  "table": {"table_name": "orders", "access_type": "ALL", "rows": 19999, "filtered": 100,
        \\    "attached_condition": "orders.`status` = 'open'"}}}}]}}
    ;
    var plan = (try fromResult(testing.allocator, &.{"EXPLAIN"}, &.{&.{text}})).?;
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 2), plan.ops.len);
    try testing.expectEqual(Kind.sort, plan.ops[0].kind);
    try testing.expectEqual(@as(?f64, 19999), plan.ops[1].est_rows);
    try testing.expectEqual(@as(?f64, 100), plan.ops[1].filtered);
}

test "a result that is no plan" {
    try testing.expect((try fromResult(testing.allocator, &.{ "Field", "Type" }, &.{&.{ "id", "int" }})) == null);
    try testing.expect((try fromResult(testing.allocator, &.{"EXPLAIN"}, &.{&.{"{ not json"}})) == null);
}
