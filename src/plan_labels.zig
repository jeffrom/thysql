//! Draws a query plan on its statement: each table access labels the table it reads, a filter
//! labels the conditions it checks, and sorts, grouping and materialization label their
//! clauses. With EXPLAIN ANALYZE the labels have the actual rows and times, and a step whose
//! estimate is far off, or that reads a large table in full, is marked as the place to look.
//!
//!   plan: EXPLAIN ANALYZE, 3.4 ms in all
//!     |
//!   1 | SELECT * FROM orders WHERE status = 'open' ORDER BY created_at
//!     |               ^^^^^^       ^^^^^^^^^^^^^^^          ---------- sorts 2000 rows
//!     |               |            |
//!     |               |            keeps 2000 of 20k rows (est 20k, 10× off)
//!     |               table scan · 20k rows · 2.3 ms
//!
//! Plan steps are tied to the statement by table aliases, and by the columns that a condition
//! names, since the server prints conditions in its own form (and sometimes rewrites them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("diagnostic.zig");
const Label = Diagnostic.Label;
const Note = Diagnostic.Note;
const Plan = @import("plan.zig");
const Op = Plan.Op;
const Semantics = @import("sql/semantics.zig");
const Analysis = Semantics.Analysis;
const Span = Semantics.Span;

/// Rows read in full above which a full scan is marked.
const large_scan_rows = 1000;
/// An estimate this many times off (either way) is marked.
const misestimate_ratio = 10;

/// The plan as labels on `sql`, which is the EXPLAIN statement. Null when no step of the plan
/// can be placed on the statement. Everything is allocated with `arena`.
pub fn annotate(arena: Allocator, plan: *const Plan.Plan, analysis: *const Analysis, sql: []const u8) Allocator.Error!?Diagnostic.Diagnostic {
    var b: Builder = .{
        .arena = arena,
        .plan = plan,
        .analysis = analysis,
        .sql = sql,
        .used_tables = try arena.alloc(bool, analysis.tables.len),
        .used_predicates = try arena.alloc(bool, analysis.predicates.len),
        .used_clauses = try arena.alloc(bool, analysis.clauses.len),
    };
    @memset(b.used_tables, false);
    @memset(b.used_predicates, false);
    @memset(b.used_clauses, false);

    for (plan.ops, 0..) |op, i| {
        switch (op.kind) {
            .access => try b.access(@intCast(i)),
            .sort => try b.sort(@intCast(i)),
            .temp_aggregate => try b.tempAggregate(@intCast(i)),
            .group_aggregate => try b.groupAggregate(@intCast(i)),
            .dedup => try b.dedup(@intCast(i)),
            .materialize => try b.materialize(@intCast(i)),
            .join => try b.hashJoin(@intCast(i)),
            else => {},
        }
    }
    if (b.labels.items.len == 0) return null;

    var message: []const u8 = "EXPLAIN: the optimizer's estimates";
    if (plan.analyzed) {
        var total: ?f64 = null;
        for (plan.ops) |op| {
            if (op.parent != null) continue;
            if (op.totalMs()) |ms| total = @max(total orelse 0, ms);
        }
        message = if (total) |ms|
            try std.fmt.allocPrint(arena, "EXPLAIN ANALYZE, {s} in all", .{try formatMs(arena, ms)})
        else
            "EXPLAIN ANALYZE";
    } else {
        try b.notes.append(arena, .{ .kind = .note, .text = "rows are estimates; EXPLAIN ANALYZE runs the statement and shows actual rows and times" });
    }

    return .{
        .severity = .plan,
        .message = message,
        .labels = b.labels.items,
        .notes = b.notes.items,
    };
}

const Builder = struct {
    arena: Allocator,
    plan: *const Plan.Plan,
    analysis: *const Analysis,
    sql: []const u8,
    labels: std.ArrayList(Label) = .empty,
    notes: std.ArrayList(Note) = .empty,
    used_tables: []bool,
    used_predicates: []bool,
    used_clauses: []bool,

    fn label(self: *Builder, span: Span, primary: bool, message: []const u8) !void {
        try self.labels.append(self.arena, .{ .start = span.start, .end = span.end, .primary = primary, .message = message });
    }

    fn note(self: *Builder, kind: Note.Kind, comptime format: []const u8, args: anytype) !void {
        try self.notes.append(self.arena, .{ .kind = kind, .text = try std.fmt.allocPrint(self.arena, format, args) });
    }

    /// The table of the statement that the plan's `name` reads: the first one not yet placed whose
    /// alias (or name, when it has none) is `name`. Plans name a derived table by its alias, and
    /// internal tables as `<temporary>` or `<derived2>`, which are on no table of the statement.
    fn findTable(self: *Builder, name: []const u8) ?u32 {
        if (name.len == 0 or name[0] == '<') return null;
        var fallback: ?u32 = null;
        for (self.analysis.tables, 0..) |table, i| {
            if (!std.ascii.eqlIgnoreCase(table.refName(), name)) continue;
            if (!self.used_tables[i]) {
                self.used_tables[i] = true;
                return @intCast(i);
            }
            if (fallback == null) fallback = @intCast(i);
        }
        return fallback;
    }

    fn access(self: *Builder, index: u32) !void {
        const plan = self.plan;
        const op = plan.ops[index];
        const table_index = self.findTable(op.table orelse return) orelse return;
        const table = self.analysis.tables[table_index];
        const parent: ?Op = if (op.parent) |p| plan.ops[p] else null;

        var parts: std.ArrayList([]const u8) = .empty;
        var hot = false;

        // How it is read.
        var method: std.ArrayList(u8) = .empty;
        if (parent != null and parent.?.kind == .hash) try method.appendSlice(self.arena, "hashed for the join: ");
        try method.appendSlice(self.arena, op.method);
        if (op.key) |key| {
            if (key.len > 0 and key[0] == '<') {
                try method.appendSlice(self.arena, " using an index built for the query");
            } else {
                try method.print(self.arena, " using {s}", .{key});
            }
        }
        if (op.covering and !std.mem.startsWith(u8, op.method, "covering")) try method.appendSlice(self.arena, " (covering)");
        try parts.append(self.arena, method.items);

        // How many rows.
        const rows = op.actual_rows orelse op.est_rows;
        const loops = op.loops orelse 1;
        if (op.never_executed) {
            try parts.append(self.arena, "never executed");
        } else if (plan.analyzed and op.actual_rows != null) {
            var text: std.ArrayList(u8) = .empty;
            try text.print(self.arena, "{s} row{s}", .{ try formatRows(self.arena, op.actual_rows.?), plural(op.actual_rows.?) });
            if (loops > 1) try text.print(self.arena, " × {s} loops", .{try formatRows(self.arena, loops)});
            if (try self.misestimate(op.est_rows, op.actual_rows)) |off| {
                try text.print(self.arena, " ({s})", .{off});
                hot = true;
            }
            try parts.append(self.arena, text.items);
        } else if (op.est_rows) |est| {
            try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "est {s} row{s}", .{ try formatRows(self.arena, est), plural(est) }));
        }
        if (plan.analyzed) {
            if (op.totalMs()) |ms| try parts.append(self.arena, try formatMs(self.arena, ms));
        }
        const read = (rows orelse 0) * loops;

        // The condition checked on its rows: a Filter above it in the tree, or its own.
        const filter: ?Op = if (parent != null and parent.?.kind == .filter) parent.? else null;
        const condition = if (filter) |f| f.condition else op.condition;
        const checks = filter != null or op.has_condition;
        var matched: std.ArrayList(u32) = .empty;
        if (checks) try self.matchPredicates(table, condition, &matched);

        var filter_text: ?[]const u8 = null;
        var filter_hot = false;
        var kept: ?f64 = null;
        if (checks) {
            if (filter) |f| {
                if (plan.analyzed and f.actual_rows != null and op.actual_rows != null) {
                    kept = f.actual_rows.?;
                    var text: std.ArrayList(u8) = .empty;
                    try text.print(self.arena, "keeps {s} of {s} rows", .{ try formatRows(self.arena, f.actual_rows.?), try formatRows(self.arena, op.actual_rows.?) });
                    if (try self.misestimate(f.est_rows, f.actual_rows)) |off| {
                        try text.print(self.arena, " ({s})", .{off});
                        filter_hot = true;
                    }
                    filter_text = text.items;
                } else if (f.est_rows) |est| {
                    filter_text = try std.fmt.allocPrint(self.arena, "keeps est {s} of {s} rows", .{ try formatRows(self.arena, est), try formatRows(self.arena, op.est_rows orelse est) });
                } else if (f.never_executed) {
                    filter_text = "never executed";
                }
            } else if (op.actual_filtered) |actual| {
                kept = (op.actual_rows orelse 0) * actual / 100;
                var text: std.ArrayList(u8) = .empty;
                try text.print(self.arena, "keeps {s}% of rows", .{try formatRows(self.arena, actual)});
                if (op.filtered) |est| {
                    if (try self.misestimate(est, actual)) |off| {
                        try text.print(self.arena, " ({s})", .{off});
                        filter_hot = true;
                    }
                }
                filter_text = text.items;
            } else if (op.filtered) |pct| {
                filter_text = if (pct >= 100) "checked on every row read" else try std.fmt.allocPrint(self.arena, "keeps est {s}% of rows", .{try formatRows(self.arena, pct)});
            }
        }

        // A large full scan is worth a look when a filter throws most of it away, so that an index
        // could read less, or when it is repeated for each row of another table.
        const est_kept = if (op.has_condition) op.filtered else null;
        const cut_down = if (kept) |k| k * 3 <= read else if (est_kept) |pct| pct * 3 <= 100 else false;
        const wasteful_scan = op.full_scan and read >= large_scan_rows and (cut_down or loops > 1);
        if (wasteful_scan) hot = true;

        if (matched.items.len == 0) {
            if (filter_text) |text| try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "filter {s}", .{text}));
            hot = hot or filter_hot;
        }

        try self.label(table.whole, hot, try std.mem.join(self.arena, " · ", parts.items));
        for (matched.items, 0..) |p, n| {
            const message = if (n == 0) (filter_text orelse "checked here") else "";
            try self.label(self.analysis.predicates[p].span, filter_hot, message);
        }

        // Advice: an index for a large full scan that a filter cuts down, and a histogram for a
        // condition whose estimate is far off.
        if (table.derived or matched.items.len == 0) return;
        var columns: std.ArrayList([]const u8) = .empty;
        for (matched.items) |p| try self.ownColumns(table, self.analysis.predicates[p], &columns);
        if (columns.items.len == 0) return;
        const list = try std.mem.join(self.arena, ", ", columns.items);
        if (wasteful_scan and cut_down) {
            try self.note(.help, "`{s}` is read in full ({s} rows) to filter on {s}; an index on `{s}({s})` may help", .{
                table.refName(), try formatRows(self.arena, read), try quotedList(self.arena, columns.items), table.name, list,
            });
        }
        if (filter_hot) {
            try self.note(.help, "the estimate for `{s}` is off; a histogram can correct it: `ANALYZE TABLE {s} UPDATE HISTOGRAM ON {s}`", .{
                self.spanText(self.analysis.predicates[matched.items[0]].span), table.name, list,
            });
        }
    }

    /// The predicates of `table`'s block that the condition checks: those whose columns the
    /// condition all names. Without the condition's text ("Using where"), those whose columns are
    /// all of `table`.
    fn matchPredicates(self: *Builder, table: Semantics.Table, condition: ?[]const u8, out: *std.ArrayList(u32)) !void {
        const a = self.analysis;
        const normalized: ?[]const u8 = if (condition) |c| try normalize(self.arena, c) else null;
        for (a.predicates, 0..) |predicate, i| {
            if (self.used_predicates[i] or !std.meta.eql(predicate.block, table.block)) continue;
            if (predicate.clause != .where and predicate.clause != .on) continue;
            var it = a.predicateColumns(predicate);
            var count: usize = 0;
            var all_named = true;
            var all_own = true;
            while (it.next()) |column| {
                count += 1;
                const qualifier = column.table orelse table.refName();
                if (normalized) |c| {
                    if (!mentions(c, qualifier, column.name)) all_named = false;
                }
                if (!self.belongsTo(column, table)) all_own = false;
            }
            if (count == 0) continue;
            if (if (normalized != null) all_named else all_own) {
                self.used_predicates[i] = true;
                try out.append(self.arena, @intCast(i));
            }
        }
    }

    /// True when `column` reads `table`: it is qualified with the table's name, or it is not
    /// qualified and the table is the only one of its block.
    fn belongsTo(self: *Builder, column: Semantics.Column, table: Semantics.Table) bool {
        if (column.table) |q| return std.ascii.eqlIgnoreCase(q, table.refName());
        var count: usize = 0;
        for (self.analysis.tables) |t| {
            if (t.block == table.block) count += 1;
        }
        return count == 1;
    }

    /// Adds the names of the columns of `predicate` that read `table`, without repeats.
    fn ownColumns(self: *Builder, table: Semantics.Table, predicate: Semantics.Predicate, out: *std.ArrayList([]const u8)) !void {
        var it = self.analysis.predicateColumns(predicate);
        while (it.next()) |column| {
            if (!self.belongsTo(column, table)) continue;
            var seen = false;
            for (out.items) |name| {
                if (std.ascii.eqlIgnoreCase(name, column.name)) seen = true;
            }
            if (!seen and out.items.len < 3) try out.append(self.arena, column.name);
        }
    }

    /// "est 20k, 10× off" when the estimate is `misestimate_ratio` or more off, on enough rows to matter.
    fn misestimate(self: *Builder, est: ?f64, actual: ?f64) !?[]const u8 {
        const e = est orelse return null;
        const a = actual orelse return null;
        const high = @max(e, a);
        const low = @max(@min(e, a), 1);
        if (high < 100 or high / low < misestimate_ratio) return null;
        return try std.fmt.allocPrint(self.arena, "est {s}, {d:.0}× off", .{ try formatRows(self.arena, e), high / low });
    }

    /// The next clause of `kind` that no step has labelled yet, in the order of the statement.
    fn nextClause(self: *Builder, kind: Semantics.ClauseKind) ?Span {
        for (self.analysis.clauses, 0..) |clause, i| {
            if (clause.kind != kind or self.used_clauses[i]) continue;
            self.used_clauses[i] = true;
            return clause.span;
        }
        return null;
    }

    /// The rows that op `index` takes in: its first child's output, over all loops.
    fn inputRows(self: *Builder, index: u32) ?f64 {
        const child = self.plan.firstChild(index) orelse return null;
        const op = self.plan.ops[child];
        const rows = op.actual_rows orelse op.est_rows orelse return null;
        return rows * (op.loops orelse 1);
    }

    fn sort(self: *Builder, index: u32) !void {
        const op = self.plan.ops[index];
        const span = self.nextClause(.order_by) orelse self.nextClause(.group_by) orelse return;
        const rows = self.inputRows(index);
        var text: std.ArrayList(u8) = .empty;
        if (rows) |n| {
            const prefix: []const u8 = if (self.plan.analyzed) "" else "est ";
            if (topN(op.text)) |limit| {
                try text.print(self.arena, "top-{s} sort of {s}{s} rows", .{ limit, prefix, try formatRows(self.arena, n) });
            } else {
                try text.print(self.arena, "sorts {s}{s} rows", .{ prefix, try formatRows(self.arena, n) });
            }
        } else {
            try text.appendSlice(self.arena, "sorted with a filesort");
        }
        try self.label(span, false, text.items);
    }

    fn tempAggregate(self: *Builder, index: u32) !void {
        const op = self.plan.ops[index];
        const span = self.nextClause(.group_by) orelse self.nextClause(.distinct) orelse return;
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.arena, "grouped in a temporary table");
        if (self.plan.analyzed) {
            if (op.actual_rows) |groups| {
                if (self.inputRows(index)) |rows| {
                    try text.print(self.arena, ": {s} rows into {s} groups", .{ try formatRows(self.arena, rows), try formatRows(self.arena, groups) });
                }
            }
        }
        try self.label(span, false, text.items);
    }

    fn groupAggregate(self: *Builder, index: u32) !void {
        const op = self.plan.ops[index];
        const span = self.nextClause(.group_by) orelse return;
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.arena, "grouped in index order");
        if (op.actual_rows orelse op.est_rows) |groups| {
            const prefix: []const u8 = if (op.actual_rows == null) "est " else "";
            try text.print(self.arena, ": {s}{s} groups", .{ prefix, try formatRows(self.arena, groups) });
        }
        try self.label(span, false, text.items);
    }

    fn dedup(self: *Builder, index: u32) !void {
        _ = index;
        const span = self.nextClause(.distinct) orelse return;
        try self.label(span, false, "duplicates removed with a temporary table");
    }

    /// Materialize under a derived table's access: the derived table's subquery.
    fn materialize(self: *Builder, index: u32) !void {
        const op = self.plan.ops[index];
        const parent = self.plan.ops[op.parent orelse return];
        const name = parent.table orelse return;
        for (self.analysis.tables) |table| {
            if (!table.derived or !std.ascii.eqlIgnoreCase(table.refName(), name)) continue;
            var parts: std.ArrayList([]const u8) = .empty;
            if (op.actual_rows) |rows| {
                try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "materialized: {s} rows", .{try formatRows(self.arena, rows)}));
            } else if (op.est_rows) |rows| {
                try parts.append(self.arena, try std.fmt.allocPrint(self.arena, "materialized: est {s} rows", .{try formatRows(self.arena, rows)}));
            } else {
                try parts.append(self.arena, "materialized");
            }
            if (self.plan.analyzed) {
                if (op.totalMs()) |ms| try parts.append(self.arena, try formatMs(self.arena, ms));
            }
            try self.label(table.span, false, try std.mem.join(self.arena, " · ", parts.items));
            return;
        }
    }

    /// A hash join: the condition it joins on.
    fn hashJoin(self: *Builder, index: u32) !void {
        const op = self.plan.ops[index];
        if (std.mem.indexOf(u8, op.text, "hash join") == null) return;
        const condition = try normalize(self.arena, op.condition orelse return);
        for (self.analysis.predicates, 0..) |predicate, i| {
            if (self.used_predicates[i] or predicate.clause != .on and predicate.clause != .where) continue;
            var it = self.analysis.predicateColumns(predicate);
            var count: usize = 0;
            var all = true;
            while (it.next()) |column| {
                count += 1;
                const q = column.table orelse {
                    all = false;
                    break;
                };
                if (!mentions(condition, q, column.name)) all = false;
            }
            if (count < 2 or !all) continue;
            self.used_predicates[i] = true;
            if (std.mem.indexOf(u8, condition, "cast(") != null) {
                try self.label(predicate.span, true, "hash join on values cast to another type");
                try self.note(.note, "`{s}` compares columns of different types, so both sides are converted, and no index can be used for it", .{self.spanText(predicate.span)});
            } else {
                try self.label(predicate.span, false, "hash join");
            }
            return;
        }
    }

    fn spanText(self: *Builder, span: Span) []const u8 {
        return self.sql[span.start..span.end];
    }
};

/// "5" in "Sort: t DESC, limit input to 5 row(s) per chunk".
fn topN(text: []const u8) ?[]const u8 {
    const marker = "limit input to ";
    const at = std.mem.indexOf(u8, text, marker) orelse return null;
    const rest = text[at + marker.len ..];
    var len: usize = 0;
    while (len < rest.len and std.ascii.isDigit(rest[len])) len += 1;
    return if (len > 0) rest[0..len] else null;
}

/// The condition without backticks, for `mentions`.
fn normalize(arena: Allocator, condition: []const u8) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, condition.len);
    var n: usize = 0;
    for (condition) |byte| {
        if (byte == '`') continue;
        out[n] = byte;
        n += 1;
    }
    return out[0..n];
}

/// True when `condition` names `qualifier.name`, as a whole name: `o.status` in `(o.status =
/// 'open')` or `(db.o.status = 'open')`, but not in `(xo.status2 = 1)`. Case is ignored.
fn mentions(condition: []const u8, qualifier: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (start + qualifier.len + 1 + name.len <= condition.len) {
        const at = indexOfIgnoreCase(condition[start..], qualifier) orelse return false;
        const begin = start + at;
        start = begin + 1;
        if (begin > 0 and isNameByte(condition[begin - 1])) continue;
        const dot = begin + qualifier.len;
        if (dot >= condition.len or condition[dot] != '.') continue;
        const name_start = dot + 1;
        const name_end = name_start + name.len;
        if (name_end > condition.len or !std.ascii.eqlIgnoreCase(condition[name_start..name_end], name)) continue;
        if (name_end < condition.len and isNameByte(condition[name_end])) continue;
        return true;
    }
    return false;
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn quotedList(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, i| {
        if (i > 0) try out.appendSlice(arena, if (i + 1 == names.len) " and " else ", ");
        try out.print(arena, "`{s}`", .{name});
    }
    return out.items;
}

fn plural(n: f64) []const u8 {
    return if (n == 1) "" else "s";
}

/// A row count, short: 0.99, 5, 1990, 20k, 1.2M.
pub fn formatRows(arena: Allocator, n: f64) Allocator.Error![]const u8 {
    if (n < 10 and n != @round(n)) return trimZeros(try std.fmt.allocPrint(arena, "{d:.2}", .{n}));
    if (n < 10_000) return std.fmt.allocPrint(arena, "{d:.0}", .{n});
    const units = [_]struct { f64, []const u8 }{ .{ 1e9, "G" }, .{ 1e6, "M" }, .{ 1e3, "k" } };
    for (units) |unit| {
        if (n < unit[0]) continue;
        const scaled = n / unit[0];
        const digits = if (scaled < 10) try std.fmt.allocPrint(arena, "{d:.1}", .{scaled}) else try std.fmt.allocPrint(arena, "{d:.0}", .{scaled});
        return std.fmt.allocPrint(arena, "{s}{s}", .{ trimZeros(digits), unit[1] });
    }
    return std.fmt.allocPrint(arena, "{d:.0}", .{n});
}

/// A time in milliseconds, short: 0.04 ms, 2.1 ms, 380 ms, 1.2 s.
pub fn formatMs(arena: Allocator, ms: f64) Allocator.Error![]const u8 {
    if (ms < 1) return std.fmt.allocPrint(arena, "{s} ms", .{trimZeros(try std.fmt.allocPrint(arena, "{d:.2}", .{ms}))});
    if (ms < 10) return std.fmt.allocPrint(arena, "{s} ms", .{trimZeros(try std.fmt.allocPrint(arena, "{d:.1}", .{ms}))});
    if (ms < 1000) return std.fmt.allocPrint(arena, "{d:.0} ms", .{ms});
    return std.fmt.allocPrint(arena, "{s} s", .{trimZeros(try std.fmt.allocPrint(arena, "{d:.1}", .{ms / 1000}))});
}

/// "2.0" as "2", "0.50" as "0.5".
fn trimZeros(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text;
    var end = text.len;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    return text[0..end];
}

const testing = std.testing;
const parser = @import("sql/parser.zig");

fn expectAnnotated(sql: []const u8, columns: []const []const u8, rows: []const []const ?[]const u8, expected: []const u8) !void {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    var tree = try p.parse(sql);
    defer tree.deinit(testing.allocator);
    var analysis = try Semantics.analyze(testing.allocator, &tree, sql, .{});
    defer analysis.deinit();
    var plan = (try Plan.fromResult(testing.allocator, columns, rows)).?;
    defer plan.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const diagnostic = (try annotate(arena.allocator(), &plan, &analysis, sql)) orelse return error.NoDiagnostic;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try Diagnostic.render(&out.writer, sql, "query", diagnostic, .{});
    try testing.expectEqualStrings(expected, out.written());
}

test "EXPLAIN ANALYZE: a full scan, a misestimated filter, and a sort" {
    const sql = "EXPLAIN ANALYZE SELECT * FROM orders WHERE status = 'open' ORDER BY created_at";
    const text =
        \\-> Sort: orders.created_at  (cost=2059 rows=20349) (actual time=3.32..3.42 rows=2000 loops=1)
        \\    -> Filter: (orders.`status` = 'open')  (cost=2059 rows=20349) (actual time=0.142..3.09 rows=2000 loops=1)
        \\        -> Table scan on orders  (cost=2059 rows=20349) (actual time=0.14..2.25 rows=20000 loops=1)
    ;
    try expectAnnotated(sql, &.{"EXPLAIN"}, &.{&.{text}},
        \\plan: EXPLAIN ANALYZE, 3.4 ms in all
        \\  |
        \\1 | EXPLAIN ANALYZE SELECT * FROM orders WHERE status = 'open' ORDER BY created_at
        \\  |                               ^^^^^^       ^^^^^^^^^^^^^^^ ------------------- sorts 2000 rows
        \\  |                               |            |
        \\  |                               |            keeps 2000 of 20k rows (est 20k, 10× off)
        \\  |                               table scan · 20k rows · 2.3 ms
        \\  |
        \\  = help: `orders` is read in full (20k rows) to filter on `status`; an index on `orders(status)` may help
        \\  = help: the estimate for `status = 'open'` is off; a histogram can correct it: `ANALYZE TABLE orders UPDATE HISTOGRAM ON status`
        \\
    );
}

test "EXPLAIN ANALYZE of a join: rewritten conditions, loops, top-N sort and grouping" {
    const sql =
        \\EXPLAIN ANALYZE SELECT u.name, SUM(o.total) AS t
        \\FROM users u JOIN orders o ON o.user_id = u.id
        \\WHERE o.status = 'open' AND u.id > 10
        \\GROUP BY u.name ORDER BY t DESC LIMIT 5
    ;
    const text =
        \\-> Limit: 5 row(s)  (actual time=4.68..4.68 rows=5 loops=1)
        \\    -> Sort: t DESC, limit input to 5 row(s) per chunk  (actual time=4.68..4.68 rows=5 loops=1)
        \\        -> Table scan on <temporary>  (actual time=4.64..4.65 rows=199 loops=1)
        \\            -> Aggregate using temporary table  (actual time=4.64..4.64 rows=199 loops=1)
        \\                -> Nested loop inner join  (cost=2415 rows=1017) (actual time=0.128..4.12 rows=1990 loops=1)
        \\                    -> Filter: ((o.`status` = 'open') and (o.user_id > 10) and (o.user_id is not null))  (cost=2059 rows=1017) (actual time=0.124..3.03 rows=1990 loops=1)
        \\                        -> Table scan on o  (cost=2059 rows=20349) (actual time=0.121..2.11 rows=20000 loops=1)
        \\                    -> Single-row index lookup on u using PRIMARY (id=o.user_id)  (cost=0.25 rows=1) (actual time=427e-6..446e-6 rows=1 loops=1990)
    ;
    try expectAnnotated(sql, &.{"EXPLAIN"}, &.{&.{text}},
        \\plan: EXPLAIN ANALYZE, 4.7 ms in all
        \\  |
        \\2 | FROM users u JOIN orders o ON o.user_id = u.id
        \\  |      -------      ^^^^^^^^ table scan · 20k rows · 2.1 ms
        \\  |      |
        \\  |      single-row index lookup using PRIMARY · 1 row × 1990 loops · 0.89 ms
        \\3 | WHERE o.status = 'open' AND u.id > 10
        \\  |       ----------------- keeps 1990 of 20k rows
        \\4 | GROUP BY u.name ORDER BY t DESC LIMIT 5
        \\  | --------------- --------------- top-5 sort of 199 rows
        \\  | |
        \\  | grouped in a temporary table: 1990 rows into 199 groups
        \\  |
        \\  = help: `o` is read in full (20k rows) to filter on `status`; an index on `orders(status)` may help
        \\
    );
}

test "the traditional table: estimates, Using where, filesort" {
    const sql = "EXPLAIN SELECT * FROM orders o WHERE o.status = 'open' ORDER BY o.created_at";
    const columns = [_][]const u8{ "id", "select_type", "table", "partitions", "type", "possible_keys", "key", "key_len", "ref", "rows", "filtered", "Extra" };
    const rows = [_][]const ?[]const u8{
        &.{ "1", "SIMPLE", "o", null, "ALL", null, null, null, null, "20349", "10.00", "Using where; Using filesort" },
    };
    try expectAnnotated(sql, &columns, &rows,
        \\plan: EXPLAIN: the optimizer's estimates
        \\  |
        \\1 | EXPLAIN SELECT * FROM orders o WHERE o.status = 'open' ORDER BY o.created_at
        \\  |                       ^^^^^^^^       ----------------- --------------------- sorted with a filesort
        \\  |                       |              |
        \\  |                       |              keeps est 10% of rows
        \\  |                       full table scan · est 20k rows
        \\  |
        \\  = help: `o` is read in full (20k rows) to filter on `status`; an index on `orders(status)` may help
        \\  = note: rows are estimates; EXPLAIN ANALYZE runs the statement and shows actual rows and times
        \\
    );
}

test "a derived table: materialized, and looked up by an index built for the query" {
    const sql = "EXPLAIN ANALYZE SELECT * FROM (SELECT user_id, COUNT(*) c FROM orders GROUP BY user_id) d JOIN users u ON u.id = d.user_id";
    const text =
        \\-> Nested loop inner join  (cost=405289 rows=4e+6) (actual time=6.86..9.29 rows=2000 loops=1)
        \\    -> Table scan on u  (cost=202 rows=2000) (actual time=0.0508..0.541 rows=2000 loops=1)
        \\    -> Index lookup on d using <auto_key0> (user_id=u.id)  (cost=4294..4297 rows=10.2) (actual time=0.00402..0.00418 rows=1 loops=2000)
        \\        -> Materialize  (cost=4294..4294 rows=2000) (actual time=6.77..6.77 rows=2000 loops=1)
        \\            -> Group aggregate: count(0)  (cost=4094 rows=2000) (actual time=0.189..5.36 rows=2000 loops=1)
        \\                -> Covering index scan on orders using user_id  (cost=2059 rows=20349) (actual time=0.184..4.05 rows=20000 loops=1)
    ;
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    var tree = try p.parse(sql);
    defer tree.deinit(testing.allocator);
    var analysis = try Semantics.analyze(testing.allocator, &tree, sql, .{});
    defer analysis.deinit();
    var plan = (try Plan.fromResult(testing.allocator, &.{"EXPLAIN"}, &.{&.{text}})).?;
    defer plan.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = (try annotate(arena.allocator(), &plan, &analysis, sql)).?;

    var found_materialized = false;
    var found_lookup = false;
    var found_group = false;
    for (d.labels) |l| {
        const text_at = sql[l.start..l.end];
        if (std.mem.startsWith(u8, l.message, "materialized: 2000 rows")) {
            found_materialized = true;
            try testing.expect(std.mem.startsWith(u8, text_at, "(SELECT"));
        }
        if (std.mem.startsWith(u8, l.message, "index lookup using an index built for the query · 1 row × 2000 loops")) found_lookup = true;
        if (std.mem.eql(u8, l.message, "grouped in index order: 2000 groups")) found_group = true;
    }
    try testing.expect(found_materialized and found_lookup and found_group);
}

test "a hash join: the build side is not marked, a join on converted values is" {
    const sql = "EXPLAIN ANALYZE SELECT * FROM users u JOIN orders o ON o.total = u.name";
    const text =
        \\-> Inner hash join (cast(o.total as double) = cast(u.`name` as double))  (cost=3.94e+6 rows=3.94e+6) (actual time=2.13..23 rows=412000 loops=1)
        \\    -> Table scan on o  (cost=0.13 rows=19702) (actual time=0.411..2.59 rows=20000 loops=1)
        \\    -> Hash
        \\        -> Table scan on u  (cost=202 rows=2000) (actual time=0.0555..0.578 rows=2000 loops=1)
    ;
    try expectAnnotated(sql, &.{"EXPLAIN"}, &.{&.{text}},
        \\plan: EXPLAIN ANALYZE, 23 ms in all
        \\  |
        \\1 | EXPLAIN ANALYZE SELECT * FROM users u JOIN orders o ON o.total = u.name
        \\  |                               -------      --------    ^^^^^^^^^^^^^^^^ hash join on values cast to another type
        \\  |                               |            |
        \\  |                               |            table scan · 20k rows · 2.6 ms
        \\  |                               hashed for the join: table scan · 2000 rows · 0.58 ms
        \\  |
        \\  = note: `o.total = u.name` compares columns of different types, so both sides are converted, and no index can be used for it
        \\
    );
}

test "names in conditions" {
    try testing.expect(mentions("(o.status = 'open')", "o", "status"));
    try testing.expect(mentions("(db.o.status = 'open')", "O", "STATUS"));
    try testing.expect(!mentions("(xo.status = 1)", "o", "status"));
    try testing.expect(!mentions("(o.status2 = 1)", "o", "status"));
    try testing.expect(mentions("((a.x = 1) and (o.status = 2))", "o", "status"));
}

test "numbers and times, short" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { f64, []const u8 }{ .{ 0.99, "0.99" }, .{ 5, "5" }, .{ 1990, "1990" }, .{ 20349, "20k" }, .{ 1.25e6, "1.3M" }, .{ 0.5, "0.5" } };
    for (cases) |c| try testing.expectEqualStrings(c[1], try formatRows(arena.allocator(), c[0]));
    try testing.expectEqualStrings("0.89 ms", try formatMs(arena.allocator(), 0.88754));
    try testing.expectEqualStrings("2.1 ms", try formatMs(arena.allocator(), 2.11));
    try testing.expectEqualStrings("380 ms", try formatMs(arena.allocator(), 380.2));
    try testing.expectEqualStrings("1.2 s", try formatMs(arena.allocator(), 1234));
}
