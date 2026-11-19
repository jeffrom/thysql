//! Syntax checks and completion candidates for MySQL statements, from the ANTLR4 parser in
//! src/sql/antlr (through its C shim, src/sql/antlr/shim.h). Offsets are byte offsets into
//! the UTF-8 input. Returned slices and their strings belong to the caller and are freed with
//! freeErrors() and freeCandidates().

const std = @import("std");
const c = @import("mysql_parser_c");

/// SQL modes that change how the parser reads the input. Same bits as the shim's
/// mysql_sql_mode enum.
pub const SqlMode = packed struct(u32) {
    ansi_quotes: bool = false,
    high_not_precedence: bool = false,
    pipes_as_concat: bool = false,
    ignore_space: bool = false,
    no_backslash_escapes: bool = false,
    _: u27 = 0,
};

/// A syntax or lexer error.
pub const Error = struct {
    /// Byte offsets of the offending text in the input, end exclusive.
    start: usize,
    end: usize,
    /// 1-based line, 0-based column in code points.
    line: u32,
    column: u32,
    /// Owned by the caller. For example: `"FROM" is not valid at this position, expecting an identifier`.
    message: []u8,
};

/// A parser rule that completion can stop at. The values are the generated parser's rule
/// indexes (see the shim's mysql_rule enum).
pub const Rule = enum(c_int) {
    query = c.MYSQL_RULE_QUERY,
    column_internal_ref = c.MYSQL_RULE_COLUMN_INTERNAL_REF,
    column_ref = c.MYSQL_RULE_COLUMN_REF,
    table_wild = c.MYSQL_RULE_TABLE_WILD,
    schema_ref = c.MYSQL_RULE_SCHEMA_REF,
    procedure_ref = c.MYSQL_RULE_PROCEDURE_REF,
    function_ref = c.MYSQL_RULE_FUNCTION_REF,
    trigger_ref = c.MYSQL_RULE_TRIGGER_REF,
    view_ref = c.MYSQL_RULE_VIEW_REF,
    tablespace_ref = c.MYSQL_RULE_TABLESPACE_REF,
    logfile_group_ref = c.MYSQL_RULE_LOGFILE_GROUP_REF,
    event_ref = c.MYSQL_RULE_EVENT_REF,
    engine_ref = c.MYSQL_RULE_ENGINE_REF,
    server_ref = c.MYSQL_RULE_SERVER_REF,
    filter_table_ref = c.MYSQL_RULE_FILTER_TABLE_REF,
    table_ref_with_wildcard = c.MYSQL_RULE_TABLE_REF_WITH_WILDCARD,
    table_ref = c.MYSQL_RULE_TABLE_REF,
    label_ref = c.MYSQL_RULE_LABEL_REF,
    charset_name = c.MYSQL_RULE_CHARSET_NAME,
    collation_name = c.MYSQL_RULE_COLLATION_NAME,
    user = c.MYSQL_RULE_USER,
    user_variable = c.MYSQL_RULE_USER_VARIABLE,
    system_variable = c.MYSQL_RULE_SYSTEM_VARIABLE,
    set_system_variable = c.MYSQL_RULE_SET_SYSTEM_VARIABLE,
};

/// Rules and tokens of the parse tree that its readers look for. The values are the generated
/// parser's rule indexes and token types (see the shim's mysql_tree_rule and mysql_token enums);
/// other rules have other values.
pub const NodeRule = enum(c_int) {
    query = c.MYSQL_RULE_QUERY,
    delete_statement = c.MYSQL_RULE_DELETE_STATEMENT,
    insert_statement = c.MYSQL_RULE_INSERT_STATEMENT,
    insert_from_constructor = c.MYSQL_RULE_INSERT_FROM_CONSTRUCTOR,
    fields = c.MYSQL_RULE_FIELDS,
    value_list = c.MYSQL_RULE_VALUE_LIST,
    values = c.MYSQL_RULE_VALUES,
    query_expression_body = c.MYSQL_RULE_QUERY_EXPRESSION_BODY,
    query_expression_parens = c.MYSQL_RULE_QUERY_EXPRESSION_PARENS,
    query_specification = c.MYSQL_RULE_QUERY_SPECIFICATION,
    subquery = c.MYSQL_RULE_SUBQUERY,
    common_table_expression = c.MYSQL_RULE_COMMON_TABLE_EXPRESSION,
    select_item_list = c.MYSQL_RULE_SELECT_ITEM_LIST,
    select_item = c.MYSQL_RULE_SELECT_ITEM,
    select_alias = c.MYSQL_RULE_SELECT_ALIAS,
    single_table = c.MYSQL_RULE_SINGLE_TABLE,
    derived_table = c.MYSQL_RULE_DERIVED_TABLE,
    table_alias = c.MYSQL_RULE_TABLE_ALIAS,
    update_statement = c.MYSQL_RULE_UPDATE_STATEMENT,
    column_ref = c.MYSQL_RULE_COLUMN_REF,
    table_wild = c.MYSQL_RULE_TABLE_WILD,
    table_ref = c.MYSQL_RULE_TABLE_REF,
    identifier = c.MYSQL_RULE_IDENTIFIER,
    limit_clause = c.MYSQL_RULE_LIMIT_CLAUSE,
    simple_limit_clause = c.MYSQL_RULE_SIMPLE_LIMIT_CLAUSE,
    having_clause = c.MYSQL_RULE_HAVING_CLAUSE,
    group_by_clause = c.MYSQL_RULE_GROUP_BY_CLAUSE,
    order_clause = c.MYSQL_RULE_ORDER_CLAUSE,
    select_option = c.MYSQL_RULE_SELECT_OPTION,
    where_clause = c.MYSQL_RULE_WHERE_CLAUSE,
    joined_table = c.MYSQL_RULE_JOINED_TABLE,
    explain_statement = c.MYSQL_RULE_EXPLAIN_STATEMENT,
    expr = c.MYSQL_RULE_EXPR,
    _,
};

pub const Token = enum(c_int) {
    mult_operator = c.MYSQL_TOKEN_MULT_OPERATOR,
    dot = c.MYSQL_TOKEN_DOT_SYMBOL,
    comma = c.MYSQL_TOKEN_COMMA_SYMBOL,
    open_par = c.MYSQL_TOKEN_OPEN_PAR_SYMBOL,
    close_par = c.MYSQL_TOKEN_CLOSE_PAR_SYMBOL,
    analyze = c.MYSQL_TOKEN_ANALYZE_SYMBOL,
    and_symbol = c.MYSQL_TOKEN_AND_SYMBOL,
    distinct = c.MYSQL_TOKEN_DISTINCT_SYMBOL,
    on_symbol = c.MYSQL_TOKEN_ON_SYMBOL,
    logical_and = c.MYSQL_TOKEN_LOGICAL_AND_OPERATOR,
    _,
};

/// A node of a parse tree: a rule, or a token.
pub const Node = struct {
    pub const Kind = union(enum) { rule: NodeRule, token: Token };

    kind: Kind,
    /// Byte offsets into the input, end exclusive. Empty for a rule that matched nothing, or a
    /// token that error recovery made up.
    start: usize,
    end: usize,
    /// Index of the parent; null for the root.
    parent: ?u32,
    /// Index of the first node after this one's subtree.
    next: u32,
    /// Error recovery skipped or made up this token, or left this rule incomplete.
    recovered: bool,
    /// Error recovery made up this token: it is not in the input.
    missing: bool = false,

    pub fn isRule(self: Node, rule: NodeRule) bool {
        return switch (self.kind) {
            .rule => |r| r == rule,
            .token => false,
        };
    }

    pub fn isToken(self: Node, token: Token) bool {
        return switch (self.kind) {
            .rule => false,
            .token => |t| t == token,
        };
    }
};

/// A statement's parse tree, with its errors. The nodes are in preorder: node 0 is the root, the
/// children of node i start at i + 1, and its subtree ends before `nodes[i].next`. Free it with
/// `deinit`.
pub const Tree = struct {
    nodes: []Node,
    errors: []Error,

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        for (self.errors) |e| allocator.free(e.message);
        allocator.free(self.errors);
        allocator.free(self.nodes);
        self.* = undefined;
    }

    /// The children of node `index`, in order.
    pub fn children(self: *const Tree, index: u32) Children {
        return .{ .tree = self, .at = index + 1, .end = self.nodes[index].next };
    }

    /// The first child of node `index` that is `rule`.
    pub fn child(self: *const Tree, index: u32, rule: NodeRule) ?u32 {
        var it = self.children(index);
        while (it.next()) |i| {
            if (self.nodes[i].isRule(rule)) return i;
        }
        return null;
    }

    /// The first node in the subtree of `index` (itself included) that is `rule`, in preorder.
    pub fn find(self: *const Tree, index: u32, rule: NodeRule) ?u32 {
        var i = index;
        while (i < self.nodes[index].next) : (i += 1) {
            if (self.nodes[i].isRule(rule)) return i;
        }
        return null;
    }

    /// The nearest ancestor of `index` that is `rule`.
    pub fn ancestor(self: *const Tree, index: u32, rule: NodeRule) ?u32 {
        var at = self.nodes[index].parent;
        while (at) |i| : (at = self.nodes[i].parent) {
            if (self.nodes[i].isRule(rule)) return i;
        }
        return null;
    }

    /// True when error recovery touched the subtree of `index`.
    pub fn hasRecovery(self: *const Tree, index: u32) bool {
        for (self.nodes[index..self.nodes[index].next]) |node| {
            if (node.recovered) return true;
        }
        return false;
    }

    pub const Children = struct {
        tree: *const Tree,
        at: u32,
        end: u32,

        pub fn next(self: *Children) ?u32 {
            if (self.at >= self.end) return null;
            const index = self.at;
            self.at = self.tree.nodes[index].next;
            return index;
        }
    };
};

/// A completion candidate for the caret.
pub const Candidate = struct {
    pub const Kind = enum { keyword, rule };

    kind: Kind,
    /// Owned by the caller. For a keyword, the word in upper case; for a rule, its name.
    text: []u8,
    /// For a rule candidate: the rule, when it is one of the Rule values.
    rule: ?Rule = null,
};

/// A parser for one server version and SQL mode. Not thread-safe; use one per thread.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    handle: *c.mysql_parser,

    pub fn init(allocator: std.mem.Allocator, server_version: u32, sql_mode: SqlMode) error{OutOfMemory}!Parser {
        const handle = c.mysql_parser_new(server_version, @as(u32, @bitCast(sql_mode))) orelse return error.OutOfMemory;
        return .{ .allocator = allocator, .handle = handle };
    }

    pub fn deinit(self: *Parser) void {
        c.mysql_parser_free(self.handle);
        self.* = undefined;
    }

    /// Sets the server version, as major * 10000 + minor * 100 + patch (80400 for 8.4.0).
    pub fn setVersion(self: *Parser, server_version: u32) void {
        c.mysql_parser_set_version(self.handle, server_version);
    }

    pub fn setSqlMode(self: *Parser, sql_mode: SqlMode) void {
        c.mysql_parser_set_sql_mode(self.handle, @as(u32, @bitCast(sql_mode)));
    }

    /// Parses one statement and returns its errors, in input order. An empty slice means the
    /// statement is valid. Free the result with freeErrors().
    pub fn check(self: *Parser, sql: []const u8) error{OutOfMemory}![]Error {
        return self.copyErrors(c.mysql_parser_check(self.handle, sql.ptr, sql.len));
    }

    /// Copies the `count` errors of the last parse.
    fn copyErrors(self: *Parser, count: usize) error{OutOfMemory}![]Error {
        const out = try self.allocator.alloc(Error, count);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |e| self.allocator.free(e.message);
            self.allocator.free(out);
        }

        while (done < count) : (done += 1) {
            const raw = (c.mysql_parser_error(self.handle, done) orelse break).*;
            out[done] = .{
                .start = raw.start,
                .end = raw.end,
                .line = raw.line,
                .column = raw.column,
                .message = try self.allocator.dupe(u8, std.mem.span(raw.message)),
            };
        }
        // The shim reports exactly `count` errors, so every slot is filled.
        std.debug.assert(done == count);
        return out;
    }

    /// Parses one statement and returns its parse tree, with its errors in input order. A statement
    /// with errors has the tree that error recovery built. Free the result with `Tree.deinit`.
    pub fn parse(self: *Parser, sql: []const u8) error{OutOfMemory}!Tree {
        const error_count = c.mysql_parser_parse(self.handle, sql.ptr, sql.len);
        const errors = try self.copyErrors(error_count);
        errdefer self.freeErrors(errors);

        const count = c.mysql_parser_node_count(self.handle);
        const nodes = try self.allocator.alloc(Node, count);
        if (count > 0) {
            const raw = c.mysql_parser_nodes(self.handle)[0..count];
            for (raw, nodes) |r, *n| {
                n.* = .{
                    .kind = if (r.rule >= 0) .{ .rule = @fromBackingInt(@intCast(r.rule)) } else .{ .token = @fromBackingInt(@intCast(r.token)) },
                    .start = r.start,
                    .end = r.end,
                    .parent = if (r.parent == std.math.maxInt(usize)) null else @intCast(r.parent),
                    .next = @intCast(r.next),
                    .recovered = (r.flags & c.MYSQL_NODE_ERROR) != 0,
                    .missing = (r.flags & c.MYSQL_NODE_MISSING) != 0,
                };
            }
        }
        return .{ .nodes = nodes, .errors = errors };
    }

    /// The generated parser's name for a rule, such as "querySpecification". Null before the first
    /// parse, or for a value that is no rule.
    pub fn ruleName(self: *Parser, rule: NodeRule) ?[]const u8 {
        const name = c.mysql_parser_rule_name(self.handle, @backingInt(rule)) orelse return null;
        return std.mem.span(name);
    }

    /// Returns the completion candidates for a caret at byte offset `caret`. Free the result
    /// with freeCandidates().
    pub fn candidates(self: *Parser, sql: []const u8, caret: usize) error{OutOfMemory}![]Candidate {
        const count = c.mysql_parser_candidates(self.handle, sql.ptr, sql.len, caret);
        const out = try self.allocator.alloc(Candidate, count);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |candidate| self.allocator.free(candidate.text);
            self.allocator.free(out);
        }

        while (done < count) : (done += 1) {
            const raw = (c.mysql_parser_candidate(self.handle, done) orelse break).*;
            const is_rule = raw.kind == c.MYSQL_CANDIDATE_RULE;
            const text = if (raw.text) |t| std.mem.span(t) else "";
            out[done] = .{
                .kind = if (is_rule) .rule else .keyword,
                .text = try self.allocator.dupe(u8, text),
                .rule = if (is_rule) std.enums.fromInt(Rule, raw.id) else null,
            };
        }
        std.debug.assert(done == count);
        return out;
    }

    pub fn freeErrors(self: *Parser, errors: []Error) void {
        for (errors) |e| self.allocator.free(e.message);
        self.allocator.free(errors);
    }

    pub fn freeCandidates(self: *Parser, candidates_list: []Candidate) void {
        for (candidates_list) |candidate| self.allocator.free(candidate.text);
        self.allocator.free(candidates_list);
    }
};

const testing = std.testing;

const v84: u32 = 80400;
const v57: u32 = 50700;

fn expectValid(sql: []const u8) !void {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();
    const errors = try parser.check(sql);
    defer parser.freeErrors(errors);
    if (errors.len != 0) {
        std.debug.print("expected no errors for: {s}\n  first: {s}\n", .{ sql, errors[0].message });
        return error.UnexpectedSyntaxError;
    }
}

test "valid statements parse without errors" {
    const statements = [_][]const u8{
        "SELECT a, b FROM t WHERE b = 1 ORDER BY a LIMIT 10",
        "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id LEFT JOIN t3 USING (x)",
        "SELECT COUNT(*) AS n FROM t GROUP BY a HAVING n > 1",
        "SELECT 1",
        "INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y')",
        "INSERT INTO t SELECT * FROM s ON DUPLICATE KEY UPDATE a = a + 1",
        "UPDATE t SET a = 1, b = b * 2 WHERE id IN (1, 2, 3)",
        "DELETE FROM t WHERE created < NOW() - INTERVAL 1 DAY",
        "CREATE TABLE IF NOT EXISTS t (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(64) NOT NULL DEFAULT '')",
        "CREATE INDEX idx_name ON t (name)",
        "ALTER TABLE t ADD COLUMN c INT NULL, DROP COLUMN d",
        "SHOW TABLES FROM db LIKE 't%'",
        "SHOW CREATE TABLE t",
        "SET NAMES utf8mb4",
        "SET @x = 1",
        "CALL proc(1, @x)",
        "WITH RECURSIVE c AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 5) SELECT * FROM c",
        "SELECT ROW_NUMBER() OVER (PARTITION BY a ORDER BY b) FROM t",
        "SELECT 1;",
    };
    for (statements) |sql| try expectValid(sql);
}

test "syntax errors have byte offsets and messages" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    // The error is at the end of input.
    const sql = "SELECT a FROM t WHERE";
    const errors = try parser.check(sql);
    defer parser.freeErrors(errors);
    try testing.expect(errors.len >= 1);
    try testing.expectEqual(sql.len, errors[0].start);
    try testing.expectEqual(sql.len, errors[0].end);
    try testing.expectEqual(@as(u32, 1), errors[0].line);
    try testing.expect(std.mem.startsWith(u8, errors[0].message, "unexpected end of input, expecting "));
}

test "lexer errors cover the unterminated text" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SELECT 'abc";
    const errors = try parser.check(sql);
    defer parser.freeErrors(errors);
    try testing.expect(errors.len >= 1);
    try testing.expectEqual(@as(usize, 7), errors[0].start);
    try testing.expectEqualStrings("'abc", sql[errors[0].start..errors[0].end]);
    try testing.expectEqualStrings("unrecognized text \"'abc\"", errors[0].message);
}

test "error offsets are byte offsets after multi-byte UTF-8" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    // "é" is two bytes, so the stray "t" is at byte 17, not at code point 16.
    const sql = "SELECT 'é' FORM t";
    const errors = try parser.check(sql);
    defer parser.freeErrors(errors);
    try testing.expectEqual(@as(usize, 1), errors.len);
    const at = std.mem.lastIndexOfScalar(u8, sql, 't').?;
    try testing.expectEqual(at, errors[0].start);
    try testing.expectEqualStrings("t", sql[errors[0].start..errors[0].end]);
    // The column counts code points: "SELECT 'é' FORM " has 16 of them.
    try testing.expectEqual(@as(u32, 16), errors[0].column);
}

test "errors name the offending text in quotes" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SELECT a FROM t FROM";
    const errors = try parser.check(sql);
    defer parser.freeErrors(errors);
    try testing.expect(errors.len >= 1);
    try testing.expectEqualStrings("FROM", sql[errors[0].start..errors[0].end]);
    try testing.expect(std.mem.startsWith(u8, errors[0].message, "\"FROM\" is not valid at this position"));
}

test "version gating: WITH needs MySQL 8.0" {
    const sql = "WITH c AS (SELECT 1) SELECT * FROM c";

    var old = try Parser.init(testing.allocator, v57, .{});
    defer old.deinit();
    const old_errors = try old.check(sql);
    defer old.freeErrors(old_errors);
    try testing.expect(old_errors.len > 0);

    var new = try Parser.init(testing.allocator, v84, .{});
    defer new.deinit();
    const new_errors = try new.check(sql);
    defer new.freeErrors(new_errors);
    try testing.expectEqual(@as(usize, 0), new_errors.len);

    // setVersion changes the same parser.
    new.setVersion(v57);
    const again = try new.check(sql);
    defer new.freeErrors(again);
    try testing.expect(again.len > 0);
}

test "completion after FROM offers table references" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SELECT * FROM ";
    const candidates = try parser.candidates(sql, sql.len);
    defer parser.freeCandidates(candidates);

    var found_table_ref = false;
    for (candidates) |candidate| {
        if (candidate.rule == .table_ref) found_table_ref = true;
    }
    try testing.expect(found_table_ref);
}

test "completion of a partial word offers the keyword" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SEL";
    const candidates = try parser.candidates(sql, sql.len);
    defer parser.freeCandidates(candidates);

    var found_select = false;
    for (candidates) |candidate| {
        if (candidate.kind == .keyword and std.mem.eql(u8, candidate.text, "SELECT")) found_select = true;
    }
    try testing.expect(found_select);
}

test "candidates at an empty statement offer statement keywords" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const candidates = try parser.candidates("", 0);
    defer parser.freeCandidates(candidates);
    try testing.expect(candidates.len > 0);
}

fn ruleOf(tree: *const Tree, index: u32) ?NodeRule {
    return switch (tree.nodes[index].kind) {
        .rule => |r| r,
        .token => null,
    };
}

test "parse keeps a preorder tree with byte spans" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SELECT u.id FROM users AS u WHERE u.id = 1";
    var tree = try parser.parse(sql);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    try testing.expect(tree.nodes.len > 10);
    try testing.expectEqual(NodeRule.query, ruleOf(&tree, 0).?);
    try testing.expectEqual(@as(?u32, null), tree.nodes[0].parent);
    try testing.expectEqual(@as(u32, @intCast(tree.nodes.len)), tree.nodes[0].next);
    try testing.expectEqualStrings("query", parser.ruleName(.query).?);

    const spec = tree.find(0, .query_specification).?;
    try testing.expectEqualStrings(sql, sql[tree.nodes[spec].start..tree.nodes[spec].end]);

    const single = tree.find(0, .single_table).?;
    try testing.expectEqualStrings("users AS u", sql[tree.nodes[single].start..tree.nodes[single].end]);
    const alias = tree.child(single, .table_alias).?;
    try testing.expectEqualStrings("AS u", sql[tree.nodes[alias].start..tree.nodes[alias].end]);
    try testing.expectEqual(spec, tree.ancestor(single, .query_specification).?);

    // A qualified column: the identifier after the dot has its own span.
    const column = tree.find(0, .column_ref).?;
    try testing.expectEqualStrings("u.id", sql[tree.nodes[column].start..tree.nodes[column].end]);
    var idents: [2][]const u8 = undefined;
    var n: usize = 0;
    var i = column;
    while (i < tree.nodes[column].next) : (i += 1) {
        if (tree.nodes[i].isRule(.identifier)) {
            idents[n] = sql[tree.nodes[i].start..tree.nodes[i].end];
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("u", idents[0]);
    try testing.expectEqualStrings("id", idents[1]);
}

test "parse of a statement with errors keeps the recovered tree" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SELECT a FROM t WHERE (a = 1";
    var tree = try parser.parse(sql);
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.errors.len > 0);
    try testing.expect(tree.nodes.len > 0);
    try testing.expect(tree.hasRecovery(0));
    for (tree.nodes) |node| {
        try testing.expect(node.start <= node.end);
        try testing.expect(node.end <= sql.len);
    }
}

test "parse spans are byte offsets after multi-byte UTF-8" {
    var parser = try Parser.init(testing.allocator, v84, .{});
    defer parser.deinit();

    const sql = "SELECT 'é' AS x FROM `tä`";
    var tree = try parser.parse(sql);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
    const ref = tree.find(0, .table_ref).?;
    try testing.expectEqualStrings("`tä`", sql[tree.nodes[ref].start..tree.nodes[ref].end]);
}
