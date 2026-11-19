//! Names in a statement's parse tree: its query blocks, the tables that each block names, and the
//! columns, select aliases and common table expressions it refers to, each with its byte span in
//! the statement. Diagnostics use the spans to point at the places that an error relates.
//!
//! A block is a SELECT (one `querySpecification`), UPDATE, DELETE or INSERT. Blocks nest: a
//! subquery's block has the block around it as its parent, and a column can name a table of its
//! own block or of any block around it.
//!
//! Everything is allocated in one arena, freed by `deinit`. Names are slices of the statement,
//! without their quotes, except a name with a doubled quote inside, which is copied.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const Tree = parser.Tree;

/// Byte offsets into the statement, end exclusive.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn of(node: parser.Node) Span {
        return .{ .start = node.start, .end = node.end };
    }
};

pub const BlockKind = enum { select, update, delete, insert };

pub const Block = struct {
    kind: BlockKind,
    /// The tree node of the block.
    node: u32,
    span: Span,
    /// The block around this one.
    parent: ?u32,
};

/// A table that a block names in its FROM clause (or as UPDATE's, DELETE's or INSERT's target).
pub const Table = struct {
    block: u32,
    /// The database, when the name is qualified.
    schema: ?[]const u8 = null,
    /// The table's name. For a derived table, its alias, or "" when it has none.
    name: []const u8,
    alias: ?[]const u8 = null,
    /// The table's name as written (with its database), or the subquery of a derived table.
    span: Span,
    /// The alias, without AS.
    alias_span: ?Span = null,
    /// The whole entry: name and alias.
    whole: Span,
    /// `(SELECT ...) AS name`.
    derived: bool = false,

    /// The name that columns use for the table: its alias, or else its name.
    pub fn refName(self: Table) []const u8 {
        return self.alias orelse self.name;
    }
};

/// A column reference, such as `id`, `u.id` or `db.users.id`.
pub const Column = struct {
    /// The block it is in; null outside any block, as in `SET @x = a`.
    block: ?u32,
    schema: ?[]const u8 = null,
    table: ?[]const u8 = null,
    name: []const u8,
    span: Span,
    name_span: Span,
    table_span: ?Span = null,
};

/// A select item's alias: the `total` of `SELECT SUM(x) AS total`.
pub const SelectAlias = struct {
    block: u32,
    name: []const u8,
    span: Span,
    /// The whole select item, expression and alias.
    item_span: Span,
};

/// A common table expression, `WITH name AS (...)`.
pub const Cte = struct {
    name: []const u8,
    span: Span,
};

/// The parts of a SELECT's select list, for a block that has one.
pub const SelectList = struct {
    block: u32,
    span: Span,
    /// The number of select items. `*` and `t.*` count as one each; see `wildcards`.
    items: u32,
    /// True when an item is `*` or `t.*`, so the number of columns is not known from the text.
    wildcards: bool,
    /// The queryExpressionBody that the SELECT is a part of, which ties the SELECTs of a UNION.
    body: ?u32,
};

pub const Options = struct {
    /// ANSI_QUOTES: double quotes quote identifiers.
    ansi_quotes: bool = false,
};

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    sql: []const u8,
    blocks: []Block = &.{},
    tables: []Table = &.{},
    columns: []Column = &.{},
    aliases: []SelectAlias = &.{},
    ctes: []Cte = &.{},
    select_lists: []SelectList = &.{},

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// True when block `inner` is `outer` or inside it.
    pub fn within(self: *const Analysis, inner: u32, outer: u32) bool {
        var at: ?u32 = inner;
        while (at) |b| : (at = self.blocks[b].parent) {
            if (b == outer) return true;
        }
        return false;
    }

    /// The table that `qualifier` names from `block`: one of the block's own, or else of the
    /// blocks around it, nearest first. Names are compared without regard to ASCII case.
    pub fn findTable(self: *const Analysis, block: ?u32, qualifier: []const u8) ?u32 {
        var at = block;
        while (at) |b| : (at = self.blocks[b].parent) {
            for (self.tables, 0..) |table, i| {
                if (table.block == b and std.ascii.eqlIgnoreCase(table.refName(), qualifier)) return @intCast(i);
            }
        }
        return null;
    }

    /// The index of the CTE named `name`, if there is one.
    pub fn findCte(self: *const Analysis, name: []const u8) ?u32 {
        for (self.ctes, 0..) |cte, i| {
            if (std.ascii.eqlIgnoreCase(cte.name, name)) return @intCast(i);
        }
        return null;
    }

    /// The block whose span holds `offset` most narrowly, or null when none does.
    pub fn blockAt(self: *const Analysis, offset: usize) ?u32 {
        var best: ?u32 = null;
        for (self.blocks, 0..) |block, i| {
            if (block.span.start <= offset and offset < block.span.end) {
                if (best == null or self.within(@intCast(i), best.?)) best = @intCast(i);
            }
        }
        return best;
    }
};

/// Reads the names of `tree`, which was parsed from `sql`. Free the result with `deinit`.
pub fn analyze(gpa: Allocator, tree: *const Tree, sql: []const u8, options: Options) Allocator.Error!Analysis {
    var result: Analysis = .{ .arena = .init(gpa), .sql = sql };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();

    var blocks: std.ArrayList(Block) = .empty;
    var tables: std.ArrayList(Table) = .empty;
    var columns: std.ArrayList(Column) = .empty;
    var aliases: std.ArrayList(SelectAlias) = .empty;
    var ctes: std.ArrayList(Cte) = .empty;
    var select_lists: std.ArrayList(SelectList) = .empty;

    var reader: Reader = .{ .arena = arena, .tree = tree, .sql = sql, .options = options };

    // The blocks that hold the node being read, innermost last, with the end of each one's subtree.
    const Open = struct { block: u32, next: u32 };
    var open: std.ArrayList(Open) = .empty;

    var i: u32 = 0;
    while (i < tree.nodes.len) : (i += 1) {
        while (open.items.len > 0 and i >= open.items[open.items.len - 1].next) _ = open.pop();
        const current: ?u32 = if (open.items.len > 0) open.items[open.items.len - 1].block else null;
        const node = tree.nodes[i];
        const rule = switch (node.kind) {
            .rule => |r| r,
            .token => continue,
        };

        switch (rule) {
            .query_specification, .update_statement, .delete_statement, .insert_statement => {
                const kind: BlockKind = switch (rule) {
                    .query_specification => .select,
                    .update_statement => .update,
                    .delete_statement => .delete,
                    else => .insert,
                };
                const index: u32 = @intCast(blocks.items.len);
                try blocks.append(arena, .{ .kind = kind, .node = i, .span = .of(node), .parent = current });
                try open.append(arena, .{ .block = index, .next = node.next });
                if (rule == .query_specification) {
                    if (tree.child(i, .select_item_list)) |list| try select_lists.append(arena, reader.selectList(index, i, list));
                }
            },
            .single_table => {
                const block = current orelse continue;
                const ref = tree.child(i, .table_ref) orelse continue;
                if (try reader.table(block, ref, tree.child(i, .table_alias), .of(node))) |t| try tables.append(arena, t);
            },
            .table_ref => {
                // DELETE FROM t [alias] and INSERT INTO t name their table outside singleTable.
                const block = current orelse continue;
                const parent = node.parent orelse continue;
                const p = tree.nodes[parent];
                if (!p.isRule(.delete_statement) and !p.isRule(.insert_statement)) continue;
                if (p.isRule(.delete_statement) and blocks.items[block].node != parent) continue;
                const alias = if (p.isRule(.delete_statement)) nextSiblingRule(tree, i, .table_alias) else null;
                var whole: Span = .of(node);
                if (alias) |a| whole.end = tree.nodes[a].end;
                if (try reader.table(block, i, alias, whole)) |t| try tables.append(arena, t);
            },
            .derived_table => {
                const block = current orelse continue;
                const subquery = tree.child(i, .subquery) orelse continue;
                var t: Table = .{
                    .block = block,
                    .name = "",
                    .span = .of(tree.nodes[subquery]),
                    .whole = .of(node),
                    .derived = true,
                };
                if (tree.child(i, .table_alias)) |alias| {
                    if (try reader.identifierIn(alias)) |name| {
                        t.name = name.text;
                        t.alias = name.text;
                        t.alias_span = name.span;
                    }
                }
                try tables.append(arena, t);
            },
            .column_ref => {
                if (tree.hasRecovery(i)) continue;
                if (try reader.column(current, i)) |c| try columns.append(arena, c);
            },
            .select_alias => {
                const block = current orelse continue;
                const name = (try reader.aliasName(i)) orelse continue;
                const item = node.parent orelse continue;
                try aliases.append(arena, .{
                    .block = block,
                    .name = name.text,
                    .span = name.span,
                    .item_span = .of(tree.nodes[item]),
                });
            },
            .common_table_expression => {
                const ident = tree.child(i, .identifier) orelse continue;
                const name = try reader.name(ident);
                try ctes.append(arena, .{ .name = name, .span = .of(tree.nodes[ident]) });
            },
            else => {},
        }
    }

    result.blocks = blocks.items;
    result.tables = tables.items;
    result.columns = columns.items;
    result.aliases = aliases.items;
    result.ctes = ctes.items;
    result.select_lists = select_lists.items;
    return result;
}

/// The first sibling after node `index` that is `rule`.
fn nextSiblingRule(tree: *const Tree, index: u32, rule: parser.NodeRule) ?u32 {
    const parent = tree.nodes[index].parent orelse return null;
    var it = tree.children(parent);
    var seen = false;
    while (it.next()) |c| {
        if (c == index) {
            seen = true;
        } else if (seen and tree.nodes[c].isRule(rule)) {
            return c;
        }
    }
    return null;
}

const Name = struct { text: []const u8, span: Span };

const Reader = struct {
    arena: Allocator,
    tree: *const Tree,
    sql: []const u8,
    options: Options,

    /// The identifiers in the subtree of `index`, in order, up to `out.len` of them. Returns how many.
    fn identifiers(self: *const Reader, index: u32, out: []u32) usize {
        var n: usize = 0;
        var i = index;
        const end = self.tree.nodes[index].next;
        while (i < end) {
            if (self.tree.nodes[i].isRule(.identifier)) {
                if (n < out.len) out[n] = i;
                n += 1;
                i = self.tree.nodes[i].next;
            } else {
                i += 1;
            }
        }
        return n;
    }

    /// The name that identifier node `index` spells, without its quotes.
    fn name(self: *const Reader, index: u32) Allocator.Error![]const u8 {
        const node = self.tree.nodes[index];
        return unquote(self.arena, self.sql[node.start..node.end], self.options);
    }

    fn identifierIn(self: *const Reader, index: u32) Allocator.Error!?Name {
        const ident = self.tree.find(index, .identifier) orelse return null;
        if (self.tree.nodes[ident].start == self.tree.nodes[ident].end) return null;
        return .{ .text = try self.name(ident), .span = .of(self.tree.nodes[ident]) };
    }

    fn table(self: *const Reader, block: u32, ref: u32, alias: ?u32, whole: Span) Allocator.Error!?Table {
        if (self.tree.hasRecovery(ref)) return null;
        var parts: [2]u32 = undefined;
        const n = self.identifiers(ref, &parts);
        if (n == 0 or n > 2) return null;
        var t: Table = .{
            .block = block,
            .name = try self.name(parts[n - 1]),
            .span = .of(self.tree.nodes[ref]),
            .whole = whole,
        };
        if (n == 2) t.schema = try self.name(parts[0]);
        if (alias) |a| {
            if (try self.identifierIn(a)) |found| {
                t.alias = found.text;
                t.alias_span = found.span;
            }
        }
        return t;
    }

    fn column(self: *const Reader, block: ?u32, index: u32) Allocator.Error!?Column {
        var parts: [3]u32 = undefined;
        const n = self.identifiers(index, &parts);
        if (n == 0 or n > 3) return null;
        const last = parts[n - 1];
        if (self.tree.nodes[last].start == self.tree.nodes[last].end) return null;
        var c: Column = .{
            .block = block,
            .name = try self.name(last),
            .span = .of(self.tree.nodes[index]),
            .name_span = .of(self.tree.nodes[last]),
        };
        if (n >= 2) {
            c.table = try self.name(parts[n - 2]);
            c.table_span = .of(self.tree.nodes[parts[n - 2]]);
        }
        if (n == 3) c.schema = try self.name(parts[0]);
        return c;
    }

    /// The name of a selectAlias: an identifier, or a quoted string.
    fn aliasName(self: *const Reader, index: u32) Allocator.Error!?Name {
        if (try self.identifierIn(index)) |found| return found;
        // AS 'text': the alias is the string's text.
        const node = self.tree.nodes[index];
        var text = std.mem.trim(u8, self.sql[node.start..node.end], " \t\r\n");
        var start = node.start;
        if (std.ascii.startsWithIgnoreCase(text, "AS")) {
            const rest = std.mem.trimStart(u8, text[2..], " \t\r\n");
            start += text.len - rest.len;
            text = rest;
        }
        if (text.len < 2 or (text[0] != '\'' and text[0] != '"')) return null;
        return .{ .text = text[1 .. text.len - 1], .span = .{ .start = start, .end = start + text.len } };
    }

    fn selectList(self: *const Reader, block: u32, spec: u32, list: u32) SelectList {
        var items: u32 = 0;
        var wildcards = false;
        var it = self.tree.children(list);
        while (it.next()) |c| {
            const node = self.tree.nodes[c];
            if (node.isRule(.select_item)) {
                items += 1;
                if (self.tree.child(c, .table_wild) != null) wildcards = true;
            } else if (node.isToken(.mult_operator)) {
                items += 1;
                wildcards = true;
            }
        }
        // querySpecification -> queryPrimary -> queryExpressionBody, when it is part of a UNION.
        var body: ?u32 = null;
        if (self.tree.nodes[spec].parent) |primary| {
            if (self.tree.nodes[primary].parent) |p| {
                if (self.tree.nodes[p].isRule(.query_expression_body)) body = p;
            }
        }
        return .{ .block = block, .span = .of(self.tree.nodes[list]), .items = items, .wildcards = wildcards, .body = body };
    }
};

/// `text` without its quotes: backticks, or double quotes with ANSI_QUOTES. A doubled quote inside
/// stands for one, so such a name is copied.
pub fn unquote(arena: Allocator, text: []const u8, options: Options) Allocator.Error![]const u8 {
    if (text.len < 2) return text;
    const q = text[0];
    if (!(q == '`' or (q == '"' and options.ansi_quotes)) or text[text.len - 1] != q) return text;
    const inner = text[1 .. text.len - 1];
    const doubled = [2]u8{ q, q };
    if (std.mem.indexOf(u8, inner, &doubled) == null) return inner;
    return std.mem.replaceOwned(u8, arena, inner, &doubled, doubled[0..1]);
}

const testing = std.testing;

fn analyzed(parser_handle: *parser.Parser, sql: []const u8) !struct { tree: Tree, analysis: Analysis } {
    var tree = try parser_handle.parse(sql);
    errdefer tree.deinit(testing.allocator);
    const analysis = try analyze(testing.allocator, &tree, sql, .{});
    return .{ .tree = tree, .analysis = analysis };
}

fn spanText(sql: []const u8, span: Span) []const u8 {
    return sql[span.start..span.end];
}

test "tables, aliases and columns of a join" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const sql = "SELECT u.id, name FROM users u JOIN shop.orders AS o ON o.user_id = u.id";
    var r = try analyzed(&p, sql);
    defer r.tree.deinit(testing.allocator);
    defer r.analysis.deinit();
    const a = &r.analysis;

    try testing.expectEqual(@as(usize, 1), a.blocks.len);
    try testing.expectEqual(@as(usize, 2), a.tables.len);
    try testing.expectEqualStrings("users", a.tables[0].name);
    try testing.expectEqualStrings("u", a.tables[0].alias.?);
    try testing.expectEqualStrings("users u", spanText(sql, a.tables[0].whole));
    try testing.expectEqualStrings("shop", a.tables[1].schema.?);
    try testing.expectEqualStrings("orders", a.tables[1].name);
    try testing.expectEqualStrings("o", spanText(sql, a.tables[1].alias_span.?));

    try testing.expectEqual(@as(usize, 4), a.columns.len);
    try testing.expectEqualStrings("u", a.columns[0].table.?);
    try testing.expectEqualStrings("id", a.columns[0].name);
    try testing.expectEqualStrings("u.id", spanText(sql, a.columns[0].span));
    try testing.expectEqualStrings("name", a.columns[1].name);
    try testing.expectEqual(@as(?[]const u8, null), a.columns[1].table);
    try testing.expectEqual(@as(?u32, 1), a.findTable(0, "O"));
    try testing.expectEqual(@as(?u32, null), a.findTable(0, "orders"));
}

test "subqueries have their own blocks, and see the tables around them" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const sql = "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM s WHERE s.k = t.k) AND x IN (SELECT y FROM (SELECT y FROM z) AS d)";
    var r = try analyzed(&p, sql);
    defer r.tree.deinit(testing.allocator);
    defer r.analysis.deinit();
    const a = &r.analysis;

    try testing.expectEqual(@as(usize, 4), a.blocks.len);
    try testing.expectEqual(@as(?u32, null), a.blocks[0].parent);
    try testing.expectEqual(@as(?u32, 0), a.blocks[1].parent);
    // t is block 0's, s block 1's: from block 1, both are visible.
    try testing.expectEqual(@as(?u32, 0), a.findTable(1, "t"));
    try testing.expectEqual(@as(?u32, 1), a.findTable(1, "s"));
    try testing.expectEqual(@as(?u32, null), a.findTable(0, "s"));
    // The derived table belongs to the block that names it.
    var derived: ?Table = null;
    for (a.tables) |t| {
        if (t.derived) derived = t;
    }
    try testing.expectEqualStrings("d", derived.?.name);
    try testing.expectEqual(@as(u32, 2), derived.?.block);
}

test "select aliases, CTEs, quoted names and select lists" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const sql = "WITH c AS (SELECT 1 AS n) SELECT `my col`, SUM(n) AS total, c.* FROM c UNION SELECT 1, 2";
    var r = try analyzed(&p, sql);
    defer r.tree.deinit(testing.allocator);
    defer r.analysis.deinit();
    const a = &r.analysis;

    try testing.expectEqual(@as(usize, 1), a.ctes.len);
    try testing.expectEqualStrings("c", a.ctes[0].name);
    try testing.expectEqualStrings("my col", a.columns[0].name);
    try testing.expectEqual(@as(usize, 2), a.aliases.len);
    try testing.expectEqualStrings("total", a.aliases[1].name);
    try testing.expectEqualStrings("SUM(n) AS total", spanText(sql, a.aliases[1].item_span));

    try testing.expectEqual(@as(usize, 3), a.select_lists.len);
    const first = a.select_lists[1];
    const second = a.select_lists[2];
    try testing.expectEqual(@as(u32, 3), first.items);
    try testing.expect(first.wildcards);
    try testing.expectEqual(@as(u32, 2), second.items);
    try testing.expect(first.body != null);
    try testing.expectEqual(first.body, second.body);
}

test "UPDATE, DELETE and INSERT name their tables" {
    var p = try parser.Parser.init(testing.allocator, 80400, .{});
    defer p.deinit();
    const statements = [_]struct { sql: []const u8, table: []const u8, kind: BlockKind }{
        .{ .sql = "UPDATE users u SET u.name = 'x' WHERE u.id = 1", .table = "users", .kind = .update },
        .{ .sql = "DELETE FROM users WHERE id = 1", .table = "users", .kind = .delete },
        .{ .sql = "INSERT INTO users (id, name) VALUES (1, 'x')", .table = "users", .kind = .insert },
    };
    for (statements) |s| {
        var r = try analyzed(&p, s.sql);
        defer r.tree.deinit(testing.allocator);
        defer r.analysis.deinit();
        try testing.expectEqual(s.kind, r.analysis.blocks[0].kind);
        try testing.expectEqualStrings(s.table, r.analysis.tables[0].name);
        try testing.expect(r.analysis.columns.len >= 1);
    }
}
