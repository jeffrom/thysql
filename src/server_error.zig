//! Explains a server error by pointing at the statement: the parse tree and its names say where
//! the column, table or clause that the error is about is, and which other places it relates to.
//! The server's message stays the authority; this only adds labels and hints under it.
//!
//! An error that is not understood, or a statement whose names cannot be found, gives no
//! diagnostic, and only the server's message is shown.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("diagnostic.zig");
const Label = Diagnostic.Label;
const Note = Diagnostic.Note;
const parser = @import("sql/parser.zig");
const Tree = parser.Tree;
const Semantics = @import("sql/semantics.zig");
const Analysis = Semantics.Analysis;
const Span = Semantics.Span;
const Names = @import("sql_completion.zig").Names;
const keywords = @import("sql/keywords.zig");

/// Server error codes that are explained.
pub const Code = struct {
    pub const parse_error: u32 = 1064; // ER_PARSE_ERROR
    pub const non_uniq_error: u32 = 1052; // ER_NON_UNIQ_ERROR: Column 'x' in field list is ambiguous
    pub const bad_field_error: u32 = 1054; // ER_BAD_FIELD_ERROR: Unknown column 'x' in 'where clause'
    pub const nonuniq_table: u32 = 1066; // ER_NONUNIQ_TABLE: Not unique table/alias: 'x'
    pub const wrong_value_count_on_row: u32 = 1136; // ER_WRONG_VALUE_COUNT_ON_ROW
    pub const no_such_table: u32 = 1146; // ER_NO_SUCH_TABLE: Table 'db.t' doesn't exist
    pub const wrong_number_of_columns_in_select: u32 = 1222; // ER_WRONG_NUMBER_OF_COLUMNS_IN_SELECT
    pub const derived_must_have_alias: u32 = 1248; // ER_DERIVED_MUST_HAVE_ALIAS
};

pub const Input = struct {
    errno: u32,
    /// The server's message.
    message: []const u8,
    sql: []const u8,
    tree: *const Tree,
    analysis: *const Analysis,
    /// The names of the server, for columns and tables that the statement might have meant.
    names: ?*const Names = null,
};

/// The diagnostic for the error, or null when there is nothing to add to the server's message.
/// Everything is allocated with `arena`.
pub fn explain(arena: Allocator, input: Input) Allocator.Error!?Diagnostic.Diagnostic {
    var b: Builder = .{ .arena = arena, .input = input };
    const found = switch (input.errno) {
        Code.parse_error => try b.parseError(),
        Code.non_uniq_error => try b.ambiguousColumn(),
        Code.bad_field_error => try b.unknownColumn(),
        Code.nonuniq_table => try b.duplicateAlias(),
        Code.wrong_value_count_on_row => try b.valueCount(),
        Code.no_such_table => try b.unknownTable(),
        Code.wrong_number_of_columns_in_select => try b.unionColumns(),
        Code.derived_must_have_alias => try b.derivedAlias(),
        else => false,
    };
    if (!found or b.labels.items.len == 0) return null;
    return .{ .labels = b.labels.items, .notes = b.notes.items };
}

const Builder = struct {
    arena: Allocator,
    input: Input,
    labels: std.ArrayList(Label) = .empty,
    notes: std.ArrayList(Note) = .empty,

    fn label(self: *Builder, span: Span, primary: bool, comptime format: []const u8, args: anytype) !void {
        try self.labels.append(self.arena, .{
            .start = span.start,
            .end = span.end,
            .primary = primary,
            .message = try std.fmt.allocPrint(self.arena, format, args),
        });
    }

    fn note(self: *Builder, kind: Note.Kind, comptime format: []const u8, args: anytype) !void {
        try self.notes.append(self.arena, .{ .kind = kind, .text = try std.fmt.allocPrint(self.arena, format, args) });
    }

    // ER_PARSE_ERROR: the parser's first error, and the parenthesis that was left open when the
    // statement ended too soon.
    fn parseError(self: *Builder) !bool {
        const tree = self.input.tree;
        if (tree.errors.len == 0) return false;
        const first = tree.errors[0];
        try self.label(.{ .start = first.start, .end = first.end }, true, "{s}", .{first.message});

        if (first.start >= std.mem.trimEnd(u8, self.input.sql, " \t\r\n;").len) {
            if (unclosedParen(tree)) |open| {
                try self.label(.{ .start = open, .end = open + 1 }, false, "this `(` is never closed", .{});
            }
        }

        // A reserved word where a name goes: say how to use it as one.
        const word = self.input.sql[first.start..first.end];
        if (isReserved(word) and namesNext(tokenBefore(tree, self.input.sql, first.start))) {
            try self.note(.help, "`{s}` is a reserved word; to use it as a name, quote it: `` `{s}` ``", .{ word, word });
        }
        return true;
    }

    // ER_NON_UNIQ_ERROR: the column, and each table that has a column of that name.
    fn ambiguousColumn(self: *Builder) !bool {
        const name = quoted(self.input.message, 0) orelse return false;
        const a = self.input.analysis;
        var block: ?u32 = null;
        var first = true;
        for (a.columns) |column| {
            if (column.table != null or !std.ascii.eqlIgnoreCase(column.name, name)) continue;
            try self.label(column.span, true, "{s}", .{if (first) "ambiguous" else ""});
            if (first) block = column.block;
            first = false;
        }
        if (first) return false;

        // The tables that might hold it: the ones the names know to have it, or all of them when
        // the names know none of their columns.
        var holders: std.ArrayList(u32) = .empty;
        var known_any = false;
        var visible: std.ArrayList(u32) = .empty;
        var at = block;
        while (at) |b| : (at = a.blocks[b].parent) {
            for (a.tables, 0..) |table, i| {
                if (table.block != b) continue;
                try visible.append(self.arena, @intCast(i));
                const columns = self.columnsOf(table) orelse continue;
                known_any = true;
                if (containsIgnoreCase(columns, name)) try holders.append(self.arena, @intCast(i));
            }
        }
        const which = if (known_any) holders.items else visible.items;
        for (which) |i| {
            const table = a.tables[i];
            if (known_any) {
                try self.label(table.whole, false, "`{s}` has a column `{s}`", .{ table.refName(), name });
            } else {
                try self.label(table.whole, false, "could be from `{s}`", .{table.refName()});
            }
        }
        if (which.len > 0) {
            var list: std.ArrayList(u8) = .empty;
            for (which, 0..) |i, n| {
                if (n > 0) try list.appendSlice(self.arena, if (n + 1 == which.len) " or " else ", ");
                try list.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "`{s}.{s}`", .{ a.tables[i].refName(), name }));
            }
            try self.note(.help, "qualify it: {s}", .{list.items});
        }
        return true;
    }

    // ER_BAD_FIELD_ERROR: the column; the table its qualifier names; a select alias that a WHERE
    // cannot see; or a column of the statement's tables with a similar name.
    fn unknownColumn(self: *Builder) !bool {
        const full = quoted(self.input.message, 0) orelse return false;
        const clause = quoted(self.input.message, 1) orelse "";
        const a = self.input.analysis;

        // `t.c` or `db.t.c`: the name is the last part, the qualifier the one before.
        var parts = std.mem.splitBackwardsScalar(u8, full, '.');
        const name = parts.next().?;
        const qualifier = parts.next();

        var found: ?Semantics.Column = null;
        for (a.columns) |column| {
            if (!std.ascii.eqlIgnoreCase(column.name, name)) continue;
            if (qualifier) |q| {
                const t = column.table orelse continue;
                if (!std.ascii.eqlIgnoreCase(t, q)) continue;
            }
            found = column;
            break;
        }
        const column = found orelse return false;
        try self.label(column.span, true, "unknown column", .{});

        if (qualifier) |q| {
            const index = a.findTable(column.block, q) orelse {
                try self.note(.note, "no table or alias here is named `{s}`", .{q});
                return true;
            };
            const table = a.tables[index];
            if (table.derived) {
                try self.label(table.whole, false, "`{s}` is this derived table", .{q});
            } else if (table.alias != null) {
                try self.label(table.whole, false, "`{s}` is `{s}`", .{ q, table.name });
            } else {
                try self.label(table.whole, false, "`{s}` is named here", .{q});
            }
            if (self.columnsOf(table)) |columns| {
                if (closest(columns, name)) |suggestion| {
                    try self.note(.help, "did you mean `{s}.{s}`?", .{ q, suggestion });
                }
            }
            return true;
        }

        // A select alias of the same block, which WHERE, ON and GROUP BY ... cannot use.
        for (a.aliases) |alias| {
            if (column.block == null or alias.block != column.block.?) continue;
            if (!std.ascii.eqlIgnoreCase(alias.name, name)) continue;
            try self.label(alias.span, false, "`{s}` is a select alias, defined here", .{alias.name});
            if (std.ascii.eqlIgnoreCase(clause, "where clause") or std.ascii.eqlIgnoreCase(clause, "on clause")) {
                try self.note(.note, "a {s} is evaluated before the select list, so it can't use the list's aliases", .{clauseName(clause)});
                try self.note(.help, "repeat the expression, or filter on the alias in HAVING", .{});
            }
            return true;
        }

        // A column with a similar name in one of the tables the column can see.
        var best: ?struct { table: u32, column: []const u8, distance: usize } = null;
        var at = column.block;
        while (at) |b| : (at = a.blocks[b].parent) {
            for (a.tables, 0..) |table, i| {
                if (table.block != b) continue;
                const columns = self.columnsOf(table) orelse continue;
                for (columns) |candidate| {
                    const d = distance(candidate, name);
                    if (d > threshold(name)) continue;
                    if (best == null or d < best.?.distance) best = .{ .table = @intCast(i), .column = candidate, .distance = d };
                }
            }
        }
        if (best) |b| {
            const table = a.tables[b.table];
            try self.label(table.whole, false, "`{s}` has `{s}`", .{ table.refName(), b.column });
            try self.note(.help, "did you mean `{s}`?", .{b.column});
        }
        return true;
    }

    // ER_NONUNIQ_TABLE: both places that use the name.
    fn duplicateAlias(self: *Builder) !bool {
        const name = quoted(self.input.message, 0) orelse return false;
        const a = self.input.analysis;
        for (a.tables, 0..) |first, i| {
            if (!std.ascii.eqlIgnoreCase(first.refName(), name)) continue;
            for (a.tables[i + 1 ..]) |second| {
                if (second.block != first.block or !std.ascii.eqlIgnoreCase(second.refName(), name)) continue;
                try self.label(second.alias_span orelse second.span, true, "`{s}` is used again here", .{name});
                try self.label(first.alias_span orelse first.span, false, "first used here", .{});
                try self.note(.help, "give one of them another alias", .{});
                return true;
            }
        }
        return false;
    }

    // ER_NO_SUCH_TABLE: the table, and a listed table with a similar name.
    fn unknownTable(self: *Builder) !bool {
        const full = quoted(self.input.message, 0) orelse return false;
        const dot = std.mem.indexOfScalar(u8, full, '.');
        const name = if (dot) |d| full[d + 1 ..] else full;
        const a = self.input.analysis;
        for (a.tables) |table| {
            if (table.derived or !std.mem.eql(u8, table.name, name)) continue;
            try self.label(table.span, true, "no such table", .{});
            if (self.input.names) |names| {
                const schema = if (dot) |d| full[0..d] else (names.database orelse "");
                var best: ?[]const u8 = null;
                var best_distance: usize = std.math.maxInt(usize);
                for (names.tables.items) |listed| {
                    if (!std.ascii.eqlIgnoreCase(listed.schema, schema)) continue;
                    const d = distance(listed.name, name);
                    if (d <= threshold(name) and d < best_distance) {
                        best = listed.name;
                        best_distance = d;
                    }
                }
                if (best) |suggestion| try self.note(.help, "did you mean `{s}`?", .{suggestion});
            }
            return true;
        }
        return false;
    }

    // ER_WRONG_NUMBER_OF_COLUMNS_IN_SELECT: the select list of each SELECT of the UNION.
    fn unionColumns(self: *Builder) !bool {
        const a = self.input.analysis;
        for (a.select_lists, 0..) |first, i| {
            const body = first.body orelse continue;
            var differs = false;
            for (a.select_lists[i + 1 ..]) |other| {
                if (other.body == body and other.items != first.items) differs = true;
            }
            if (!differs) continue;
            try self.label(first.span, false, "{s}", .{try self.count(first)});
            for (a.select_lists[i + 1 ..]) |other| {
                if (other.body != body) continue;
                try self.label(other.span, other.items != first.items, "{s}", .{try self.count(other)});
            }
            try self.note(.note, "each SELECT of a UNION must have the same number of columns", .{});
            return true;
        }
        return false;
    }

    fn count(self: *Builder, list: Semantics.SelectList) ![]const u8 {
        const s = plural(list.items);
        if (list.wildcards) return std.fmt.allocPrint(self.arena, "{d} item{s}, with `*`", .{ list.items, s });
        return std.fmt.allocPrint(self.arena, "{d} column{s}", .{ list.items, s });
    }

    // ER_DERIVED_MUST_HAVE_ALIAS: each derived table without an alias.
    fn derivedAlias(self: *Builder) !bool {
        var found = false;
        for (self.input.analysis.tables) |table| {
            if (!table.derived or table.alias != null) continue;
            try self.label(table.span, true, "this derived table needs an alias", .{});
            found = true;
        }
        if (found) try self.note(.help, "name it: `(SELECT ...) AS d`", .{});
        return found;
    }

    // ER_WRONG_VALUE_COUNT_ON_ROW: the column list, and the row of VALUES that does not match it.
    fn valueCount(self: *Builder) !bool {
        const tree = self.input.tree;
        const row_number = rowNumber(self.input.message) orelse 1;
        const constructor = tree.find(0, .insert_from_constructor) orelse return false;
        const value_list = tree.find(constructor, .value_list) orelse return false;

        // The column list: `(a, b, c)`, or the table's columns when there is none.
        var columns: ?usize = null;
        if (tree.child(constructor, .fields)) |fields| {
            const n = 1 + countTokens(tree, fields, .comma);
            columns = n;
            try self.label(.of(tree.nodes[fields]), false, "{d} column{s}", .{ n, plural(n) });
        } else {
            for (self.input.analysis.tables) |table| {
                if (table.block != 0) continue;
                const known = self.columnsOf(table) orelse break;
                columns = known.len;
                try self.label(table.span, false, "`{s}` has {d} column{s}", .{ table.name, known.len, plural(known.len) });
                break;
            }
        }

        // The rows: each `(...)` of the value list.
        var row: usize = 0;
        var row_start: usize = 0;
        var values: usize = 0;
        var it = tree.children(value_list);
        while (it.next()) |c| {
            const node = tree.nodes[c];
            if (node.isToken(.open_par)) {
                row += 1;
                row_start = node.start;
                values = 0;
            } else if (node.isRule(.values)) {
                values = 1 + countTokens(tree, c, .comma);
            } else if (node.isToken(.close_par) and row == row_number) {
                try self.label(.{ .start = row_start, .end = node.end }, true, "{d} value{s}", .{ values, plural(values) });
                if (columns) |n| {
                    if (n != values) try self.note(.note, "row {d} has {d} value{s} for {d} column{s}", .{ row, values, plural(values), n, plural(n) });
                }
                return true;
            }
        }
        return self.labels.items.len > 0;
    }

    /// The column names of `table` that the names know, or null when they do not know them.
    fn columnsOf(self: *Builder, table: Semantics.Table) ?[]const [:0]u8 {
        if (table.derived) return null;
        const names = self.input.names orelse return null;
        if (self.input.analysis.findCte(table.name) != null and table.schema == null) return null;
        const listed = names.findTable(table.schema, table.name) orelse return null;
        if (listed.columns.items.len == 0) return null;
        return listed.columns.items;
    }
};

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// The number of `token` children of node `index`.
fn countTokens(tree: *const Tree, index: u32, token: parser.Token) usize {
    var n: usize = 0;
    var it = tree.children(index);
    while (it.next()) |c| {
        if (tree.nodes[c].isToken(token)) n += 1;
    }
    return n;
}

/// The offset of the last `(` that no `)` closes, among the tokens that were really typed.
fn unclosedParen(tree: *const Tree) ?usize {
    var stack: [64]usize = undefined;
    var depth: usize = 0;
    var overflow: usize = 0;
    for (tree.nodes) |node| {
        if (node.missing) continue;
        if (node.isToken(.open_par)) {
            if (depth < stack.len) {
                stack[depth] = node.start;
                depth += 1;
            } else overflow += 1;
        } else if (node.isToken(.close_par)) {
            if (overflow > 0) {
                overflow -= 1;
            } else if (depth > 0) depth -= 1;
        }
    }
    return if (depth > 0) stack[depth - 1] else null;
}

fn isReserved(word: []const u8) bool {
    const keyword = keywords.find(word) orelse return false;
    return keyword.reserved;
}

/// The text of the last token that ends at or before `offset`, or "" when there is none.
fn tokenBefore(tree: *const Tree, sql: []const u8, offset: usize) []const u8 {
    var found: []const u8 = "";
    for (tree.nodes) |node| {
        if (node.kind != .token or node.missing or node.start == node.end) continue;
        if (node.end > offset) continue;
        found = sql[node.start..node.end];
    }
    return found;
}

/// True when a name of a table or column usually follows `word`.
fn namesNext(word: []const u8) bool {
    const words = [_][]const u8{ "FROM", "JOIN", "INTO", "UPDATE", "TABLE", "AS", ",", ".", "SELECT", "BY" };
    for (words) |w| {
        if (std.ascii.eqlIgnoreCase(word, w)) return true;
    }
    return false;
}

/// The `n`th single-quoted part of a server message: `id` in "Column 'id' in field list is ambiguous".
fn quoted(message: []const u8, n: usize) ?[]const u8 {
    var rest = message;
    var i: usize = 0;
    while (true) : (i += 1) {
        const open = std.mem.indexOfScalar(u8, rest, '\'') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '\'') orelse return null;
        if (i == n) return rest[open + 1 .. close];
        rest = rest[close + 1 ..];
    }
}

/// N in "... at row N".
fn rowNumber(message: []const u8) ?usize {
    const at = std.mem.lastIndexOf(u8, message, "at row ") orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, message[at + 7 ..], " ."), 10) catch null;
}

/// "where clause" as "WHERE clause".
fn clauseName(clause: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(clause, "where clause")) return "WHERE clause";
    if (std.ascii.eqlIgnoreCase(clause, "on clause")) return "ON clause";
    return clause;
}

fn containsIgnoreCase(list: []const [:0]u8, name: []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(item, name)) return true;
    }
    return false;
}

/// The name in `list` closest to `name`, when one is close enough to be a likely typo.
fn closest(list: []const [:0]u8, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (list) |item| {
        const d = distance(item, name);
        if (d <= threshold(name) and d < best_distance) {
            best = item;
            best_distance = d;
        }
    }
    return best;
}

/// How many edits a name can be from another and still be suggested for it.
fn threshold(name: []const u8) usize {
    return @max(1, name.len / 3);
}

/// The edit distance between `a` and `b`, ignoring ASCII case, where swapping two neighbouring
/// letters is one edit (optimal string alignment). Names longer than 64 bytes are never close to
/// anything.
fn distance(a: []const u8, b: []const u8) usize {
    const max = 64;
    if (a.len > max or b.len > max) return std.math.maxInt(usize);
    var rows: [3][max + 1]usize = undefined; // Rows i - 2, i - 1 and i.
    for (0..b.len + 1) |j| rows[1][j] = j;
    for (a, 0..) |ca, i| {
        const current = &rows[2];
        const previous = &rows[1];
        current[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            var d = @min(@min(previous[j + 1] + 1, current[j] + 1), previous[j] + cost);
            if (i > 0 and j > 0 and std.ascii.toLower(ca) == std.ascii.toLower(b[j - 1]) and std.ascii.toLower(a[i - 1]) == std.ascii.toLower(cb)) {
                d = @min(d, rows[0][j - 1] + 1);
            }
            current[j + 1] = d;
        }
        rows[0] = rows[1];
        rows[1] = rows[2];
    }
    return rows[1][b.len];
}

test "distance counts a swap of neighbours as one edit" {
    try testing.expectEqual(@as(usize, 1), distance("nmae", "name"));
    try testing.expectEqual(@as(usize, 1), distance("Name", "nme"));
    try testing.expectEqual(@as(usize, 0), distance("ID", "id"));
    try testing.expectEqual(@as(usize, 3), distance("abc", ""));
}

const testing = std.testing;

/// Runs the explanation for `sql` and checks the rendered snippet.
fn expectExplained(errno: u32, message: []const u8, sql: []const u8, names: ?*const Names, expected: []const u8) !void {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    var tree = try p.parse(sql);
    defer tree.deinit(testing.allocator);
    var analysis = try Semantics.analyze(testing.allocator, &tree, sql, .{});
    defer analysis.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const diagnostic = (try explain(arena.allocator(), .{
        .errno = errno,
        .message = message,
        .sql = sql,
        .tree = &tree,
        .analysis = &analysis,
        .names = names,
    })) orelse return error.NoDiagnostic;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try Diagnostic.renderSnippet(&out.writer, sql, "query", diagnostic, .{});
    try testing.expectEqualStrings(expected, out.written());
}

fn testNames() !Names {
    var names = Names.init(testing.allocator);
    errdefer names.deinit();
    try names.setDatabase("shop");
    try names.addTable("shop", "users");
    try names.addColumn("shop", "users", "id");
    try names.addColumn("shop", "users", "name");
    try names.addColumn("shop", "users", "created_at");
    try names.addTable("shop", "orders");
    try names.addColumn("shop", "orders", "id");
    try names.addColumn("shop", "orders", "user_id");
    try names.addColumn("shop", "orders", "total");
    return names;
}

test "ambiguous column: the tables that have it" {
    var names = try testNames();
    defer names.deinit();
    try expectExplained(1052, "Column 'id' in field list is ambiguous",
        \\SELECT id, name
        \\FROM users u
        \\JOIN orders o ON o.user_id = u.id
    , &names,
        \\ --> query:1:8
        \\  |
        \\1 | SELECT id, name
        \\  |        ^^ ambiguous
        \\2 | FROM users u
        \\  |      ------- `u` has a column `id`
        \\3 | JOIN orders o ON o.user_id = u.id
        \\  |      -------- `o` has a column `id`
        \\  |
        \\  = help: qualify it: `u.id` or `o.id`
        \\
    );
}

test "unknown column: a typo, with the table that has the name it meant" {
    var names = try testNames();
    defer names.deinit();
    try expectExplained(1054, "Unknown column 'nmae' in 'field list'", "SELECT nmae FROM users", &names,
        \\ --> query:1:8
        \\  |
        \\1 | SELECT nmae FROM users
        \\  |        ^^^^      ----- `users` has `name`
        \\  |        |
        \\  |        unknown column
        \\  |
        \\  = help: did you mean `name`?
        \\
    );
}

test "unknown column: a select alias used in WHERE" {
    try expectExplained(1054, "Unknown column 'n' in 'where clause'", "SELECT COUNT(*) AS n FROM t WHERE n > 1", null,
        \\ --> query:1:35
        \\  |
        \\1 | SELECT COUNT(*) AS n FROM t WHERE n > 1
        \\  |                    -              ^ unknown column
        \\  |                    |
        \\  |                    `n` is a select alias, defined here
        \\  |
        \\  = note: a WHERE clause is evaluated before the select list, so it can't use the list's aliases
        \\  = help: repeat the expression, or filter on the alias in HAVING
        \\
    );
}

test "unknown column: the qualifier's table" {
    var names = try testNames();
    defer names.deinit();
    try expectExplained(1054, "Unknown column 'o.totl' in 'field list'", "SELECT o.totl FROM orders o", &names,
        \\ --> query:1:8
        \\  |
        \\1 | SELECT o.totl FROM orders o
        \\  |        ^^^^^^      -------- `o` is `orders`
        \\  |        |
        \\  |        unknown column
        \\  |
        \\  = help: did you mean `o.total`?
        \\
    );
}

test "parse error: the parenthesis left open" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const sql = "SELECT a FROM t WHERE (a = 1 AND (b = 2)";
    var tree = try p.parse(sql);
    defer tree.deinit(testing.allocator);
    var analysis = try Semantics.analyze(testing.allocator, &tree, sql, .{});
    defer analysis.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = (try explain(arena.allocator(), .{ .errno = 1064, .message = "", .sql = sql, .tree = &tree, .analysis = &analysis })).?;
    try testing.expectEqual(@as(usize, 2), d.labels.len);
    try testing.expectEqual(sql.len, d.labels[0].start);
    try testing.expectEqualStrings("(", sql[d.labels[1].start..d.labels[1].end]);
    try testing.expectEqual(@as(usize, 22), d.labels[1].start);
}

test "parse error: a reserved word as a name" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const sql = "SELECT a FROM order WHERE a = 1";
    var tree = try p.parse(sql);
    defer tree.deinit(testing.allocator);
    var analysis = try Semantics.analyze(testing.allocator, &tree, sql, .{});
    defer analysis.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = (try explain(arena.allocator(), .{ .errno = 1064, .message = "", .sql = sql, .tree = &tree, .analysis = &analysis })).?;
    try testing.expectEqualStrings("order", sql[d.labels[0].start..d.labels[0].end]);
    try testing.expectEqual(@as(usize, 1), d.notes.len);
    try testing.expect(std.mem.indexOf(u8, d.notes[0].text, "`` `order` ``") != null);
}

test "duplicate alias: both places" {
    try expectExplained(1066, "Not unique table/alias: 'a'", "SELECT 1 FROM users a JOIN orders a ON 1", null,
        \\ --> query:1:35
        \\  |
        \\1 | SELECT 1 FROM users a JOIN orders a ON 1
        \\  |                     -             ^ `a` is used again here
        \\  |                     |
        \\  |                     first used here
        \\  |
        \\  = help: give one of them another alias
        \\
    );
}

test "union: each select list's count" {
    try expectExplained(1222, "The used SELECT statements have a different number of columns", "SELECT a, b FROM t UNION SELECT c FROM s", null,
        \\ --> query:1:33
        \\  |
        \\1 | SELECT a, b FROM t UNION SELECT c FROM s
        \\  |        ----                     ^ 1 column
        \\  |        |
        \\  |        2 columns
        \\  |
        \\  = note: each SELECT of a UNION must have the same number of columns
        \\
    );
}

test "insert: the column list and the row that does not match" {
    try expectExplained(1136, "Column count doesn't match value count at row 2", "INSERT INTO t (a, b) VALUES (1, 2), (3)", null,
        \\ --> query:1:37
        \\  |
        \\1 | INSERT INTO t (a, b) VALUES (1, 2), (3)
        \\  |                ----                 ^^^ 1 value
        \\  |                |
        \\  |                2 columns
        \\  |
        \\  = note: row 2 has 1 value for 2 columns
        \\
    );
}

test "derived table without an alias, and a missing table" {
    try expectExplained(1248, "Every derived table must have its own alias", "SELECT * FROM (SELECT 1)", null,
        \\ --> query:1:15
        \\  |
        \\1 | SELECT * FROM (SELECT 1)
        \\  |               ^^^^^^^^^^ this derived table needs an alias
        \\  |
        \\  = help: name it: `(SELECT ...) AS d`
        \\
    );
    var names = try testNames();
    defer names.deinit();
    try expectExplained(1146, "Table 'shop.user' doesn't exist", "SELECT * FROM user", &names,
        \\ --> query:1:15
        \\  |
        \\1 | SELECT * FROM user
        \\  |               ^^^^ no such table
        \\  |
        \\  = help: did you mean `users`?
        \\
    );
}

test "an error that is not understood gives nothing" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const sql = "SELECT 1";
    var tree = try p.parse(sql);
    defer tree.deinit(testing.allocator);
    var analysis = try Semantics.analyze(testing.allocator, &tree, sql, .{});
    defer analysis.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try explain(arena.allocator(), .{ .errno = 1045, .message = "Access denied", .sql = sql, .tree = &tree, .analysis = &analysis })) == null);
}
