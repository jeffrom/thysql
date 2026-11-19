//! The SQL parser of the interactive client, for the server that it is connected to. The
//! parser's version and sql_mode follow the server, and the lexer options that follow the
//! sql_mode are kept here as well, whether or not the parser is on.
//!
//! The parser's first statement is slow, so it is warmed up on a background thread at startup.
//! A parser is not thread-safe, so the REPL's own parser is created only after that thread has
//! finished. The warm-up uses a throwaway parser, whose static caches the REPL's parser then shares.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mysql = @import("mysql.zig");
const parser_api = @import("sql/parser.zig");
const Parser = parser_api.Parser;
const SqlMode = parser_api.SqlMode;
const SqlLexer = @import("sql/lexer.zig");
const Semantics = @import("sql/semantics.zig");
const ServerError = @import("server_error.zig");
const Diagnostic = @import("diagnostic.zig");
const Names = @import("sql_completion.zig").Names;
const Plan = @import("plan.zig");
const PlanLabels = @import("plan_labels.zig");

/// The MySQL version the parser uses when the server's version cannot be read: the newest it knows.
pub const default_version: u32 = 80400;

/// What a MariaDB server is parsed as. MariaDB 10.2 added common table expressions and window
/// functions, which MySQL 8.0 has, so 10.2 and later get 8.0. Older MariaDB servers get 5.7.
/// MariaDB-only syntax is reported as an error here, so the parser can be turned off with
/// --no-parser.
const mariadb_version: u32 = 80000;
const mariadb_old_version: u32 = 50700;

/// Statement the warm-up parses. It touches the common rules, so most of the DFA is built.
const warm_up_sql = "SELECT a, COUNT(*) AS n FROM t JOIN u ON t.id = u.id WHERE a > 1 GROUP BY a ORDER BY a LIMIT 10";

/// The MySQL version number of a server version string, as major * 10000 + minor * 100 + patch.
/// Accepts `8.4.3`, `5.7.44-log`, `8.0.36-0ubuntu0.22.04.1` and MariaDB's `10.11.6-MariaDB`,
/// with or without MariaDB's `5.5.5-` replication prefix. A string with no version gives default_version.
pub fn versionNumber(server_version: []const u8) u32 {
    var text = server_version;
    if (std.mem.startsWith(u8, text, "5.5.5-")) text = text[6..];
    const numbers = parseNumbers(text) orelse return default_version;
    if (containsIgnoreCase(text, "mariadb")) {
        const at_least_10_2 = numbers[0] > 10 or (numbers[0] == 10 and numbers[1] >= 2);
        return if (at_least_10_2) mariadb_version else mariadb_old_version;
    }
    return numbers[0] * 10000 + numbers[1] * 100 + numbers[2];
}

/// The major, minor and patch numbers at the start of `text`. A missing minor or patch is 0.
/// Null when the text does not start with a number.
fn parseNumbers(text: []const u8) ?[3]u32 {
    var numbers: [3]u32 = .{ 0, 0, 0 };
    var index: usize = 0;
    for (&numbers, 0..) |*number, part| {
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) index += 1;
        if (index == start) {
            if (part == 0) return null;
            break;
        }
        number.* = std.fmt.parseInt(u32, text[start..index], 10) catch return null;
        if (part == 2 or index >= text.len or text[index] != '.') break;
        index += 1;
    }
    return numbers;
}

fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (needle.len > text.len) return false;
    var start: usize = 0;
    while (start + needle.len <= text.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(text[start..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The parser's sql_mode for a value such as `STRICT_TRANS_TABLES,ANSI_QUOTES`, as `SELECT @@sql_mode`
/// gives it. Names are case-insensitive, and the ones the parser does not use are ignored. ANSI
/// is the combination that the manual lists for it.
pub fn sqlModeFromText(text: []const u8) SqlMode {
    var mode: SqlMode = .{};
    var names = std.mem.splitScalar(u8, text, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(name, "ANSI")) {
            mode.ansi_quotes = true;
            mode.pipes_as_concat = true;
            mode.ignore_space = true;
        } else if (std.ascii.eqlIgnoreCase(name, "ANSI_QUOTES")) {
            mode.ansi_quotes = true;
        } else if (std.ascii.eqlIgnoreCase(name, "PIPES_AS_CONCAT")) {
            mode.pipes_as_concat = true;
        } else if (std.ascii.eqlIgnoreCase(name, "HIGH_NOT_PRECEDENCE")) {
            mode.high_not_precedence = true;
        } else if (std.ascii.eqlIgnoreCase(name, "IGNORE_SPACE")) {
            mode.ignore_space = true;
        } else if (std.ascii.eqlIgnoreCase(name, "NO_BACKSLASH_ESCAPES")) {
            mode.no_backslash_escapes = true;
        }
    }
    return mode;
}

/// The parser and the settings it follows, for one connection. Create it with `init`, and keep it
/// up to date with `refresh` after every connect and reconnect.
pub const Syntax = struct {
    /// The server's error for a syntax error, ER_PARSE_ERROR.
    pub const parse_error_code: u32 = 1064;

    allocator: Allocator,
    /// False with --no-parser. The parser is then never created, and highlighting and
    /// completion use the lexer alone.
    enabled: bool,
    /// The lexer settings for the session's sql_mode. Highlighting and completion read them,
    /// whether or not the parser is on.
    lexer: SqlLexer.Options = .{},
    /// The MySQL version number the parser uses. See versionNumber.
    version: u32 = default_version,
    sql_mode: SqlMode = .{},
    /// Created by `parser`, after the warm-up has finished.
    parser_handle: ?Parser = null,
    warm_up: ?std.Thread = null,

    /// Starts the warm-up when the parser is enabled. Free the result with `deinit`.
    pub fn init(allocator: Allocator, enabled: bool) Syntax {
        var self: Syntax = .{ .allocator = allocator, .enabled = enabled };
        if (enabled) {
            // A failed spawn is not an error: the parser is then built cold, on first use.
            self.warm_up = std.Thread.spawn(.{}, warmUp, .{}) catch null;
        }
        return self;
    }

    pub fn deinit(self: *Syntax) void {
        self.joinWarmUp();
        if (self.parser_handle) |*handle| handle.deinit();
        self.parser_handle = null;
    }

    /// Reads the server's version and sql_mode. Call it after each connect and reconnect. Errors
    /// are only allocation failures; a server that cannot answer keeps the default mode.
    pub fn refresh(self: *Syntax, db: *Mysql.DB) Allocator.Error!void {
        self.version = versionNumber(db.serverVersion());
        const row = try db.firstRowCopy(self.allocator, "SELECT @@sql_mode");
        defer if (row) |values| Mysql.freeRowCopy(self.allocator, values);
        const text: []const u8 = if (row) |values| (values[0] orelse "") else "";
        self.sql_mode = sqlModeFromText(text);
        self.lexer = .{
            .ansi_quotes = self.sql_mode.ansi_quotes,
            .no_backslash_escapes = self.sql_mode.no_backslash_escapes,
        };
        if (self.parser_handle) |*handle| {
            handle.setVersion(self.version);
            handle.setSqlMode(self.sql_mode);
        }
    }

    /// The parser for the server, or null when it is off. The first call waits for the warm-up
    /// to finish. The parser is not thread-safe: use it only from the REPL's thread.
    pub fn parser(self: *Syntax) ?*Parser {
        if (!self.enabled) return null;
        if (self.parser_handle == null) {
            self.joinWarmUp();
            self.parser_handle = Parser.init(self.allocator, self.version, self.sql_mode) catch return null;
        }
        return &self.parser_handle.?;
    }

    /// The first error in the statement of `text` that holds `cursor`, for the line being typed. Only
    /// that statement is checked. An error that reaches the end of the text is not returned, because
    /// the user is still typing it: an unfinished statement, or a string that is not closed yet. A
    /// space after the text means the user has finished it.
    /// Statements end at `delimiter` or at a backslash command, and client commands are not checked.
    /// Returns null when there is nothing to report, or when the parser is off. Free the result with
    /// `allocator`.
    pub fn firstError(self: *Syntax, allocator: Allocator, text: []const u8, cursor: usize, delimiter: []const u8) !?Problem {
        const handle = self.parser() orelse return null;
        var options = self.lexer;
        options.delimiter = delimiter;
        const statement = statementAt(text, cursor, options) orelse return null;
        const sql = text[statement.start..statement.end];
        if (std.mem.trimEnd(u8, sql, " \t\r\n").len == 0) return null;

        const errors = try handle.check(sql);
        defer handle.freeErrors(errors);
        if (errors.len == 0) return null;
        // The parser sorts its errors by position, so the first one is the one to show. An error
        // that runs to the end of the text is still being typed, unless a space follows it.
        const first = errors[0];
        if (first.end >= sql.len) return null;
        return .{
            .start = statement.start + first.start,
            .end = statement.start + first.end,
            .message = try allocator.dupe(u8, first.message),
        };
    }

    /// The completion candidates that the parser gives at `cursor` in `text`, for the statement that
    /// holds the cursor. The statement is checked only up to the cursor. Null when the parser is off,
    /// or the cursor is in a client command. Free the result with `freeCandidates`.
    pub fn candidates(self: *Syntax, text: []const u8, cursor: usize, delimiter: []const u8) Allocator.Error!?[]parser_api.Candidate {
        const handle = self.parser() orelse return null;
        var options = self.lexer;
        options.delimiter = delimiter;
        const span = statementAt(text, cursor, options) orelse return null;
        return try handle.candidates(text[span.start..cursor], cursor - span.start);
    }

    pub fn freeCandidates(self: *Syntax, list: []parser_api.Candidate) void {
        if (self.parser_handle) |*handle| handle.freeCandidates(list);
    }

    /// Explains the server's error for `sql` under its message: the lines of the statement that the
    /// error is about, with labels on the places it relates, such as the column that is ambiguous
    /// and the tables that both have it, and hints. `names` are the server's names, for "did you
    /// mean" hints. Nothing is printed when the parser is off, or the error is not one that is
    /// explained (see server_error.zig), because the server's message is enough then.
    pub fn explainError(self: *Syntax, out: *std.Io.Writer, sql: []const u8, errno: u32, message: []const u8, names: ?*const Names, display: Display) !void {
        const handle = self.parser() orelse return;
        var tree = try handle.parse(sql);
        defer tree.deinit(self.allocator);
        var analysis = try Semantics.analyze(self.allocator, &tree, sql, .{ .ansi_quotes = self.sql_mode.ansi_quotes });
        defer analysis.deinit();
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();

        const diagnostic = (try ServerError.explain(arena.allocator(), .{
            .errno = errno,
            .message = message,
            .sql = sql,
            .tree = &tree,
            .analysis = &analysis,
            .names = names,
        })) orelse return;
        const source = try displaySource(arena.allocator(), &tree, sql, display.width);
        try Diagnostic.renderSnippet(out, source, "query", diagnostic, .{ .color = display.color });
    }

    /// True when `sql` may be an EXPLAIN statement, whose result `annotatePlan` can draw. A cheap
    /// check of the first word, before the result is copied.
    pub fn mayBeExplain(sql: []const u8) bool {
        const text = std.mem.trimStart(u8, sql, " \t\r\n(");
        return std.ascii.startsWithIgnoreCase(text, "EXPLAIN") or std.ascii.startsWithIgnoreCase(text, "DESC");
    }

    /// Draws the plan that the EXPLAIN statement `sql` gave, with its column names and rows, on
    /// the statement: see plan_labels.zig. Nothing is printed when the parser is off, the statement
    /// is no EXPLAIN of a statement (such as DESCRIBE of a table), or no step of the plan can be
    /// placed on it.
    pub fn annotatePlan(self: *Syntax, out: *std.Io.Writer, sql: []const u8, columns: []const []const u8, rows: []const []const ?[]const u8, display: Display) !void {
        const handle = self.parser() orelse return;
        var tree = try handle.parse(sql);
        defer tree.deinit(self.allocator);
        if (tree.errors.len > 0) return;
        var analysis = try Semantics.analyze(self.allocator, &tree, sql, .{ .ansi_quotes = self.sql_mode.ansi_quotes });
        defer analysis.deinit();
        if (analysis.explain == null) return;

        var plan = (try Plan.fromResult(self.allocator, columns, rows)) orelse return;
        defer plan.deinit();
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const diagnostic = (try PlanLabels.annotate(arena.allocator(), &plan, &analysis, sql)) orelse return;
        const source = try displaySource(arena.allocator(), &tree, sql, display.width);
        try out.writeByte('\n');
        try Diagnostic.render(out, source, "query", diagnostic, .{ .color = display.color });
    }

    fn joinWarmUp(self: *Syntax) void {
        if (self.warm_up) |thread| {
            thread.join();
            self.warm_up = null;
        }
    }
};

/// How diagnostics are drawn.
pub const Display = struct {
    color: bool = false,
    /// The terminal's width. A statement with a longer line is broken at its clauses. 0 for no limit.
    width: usize = 0,
};

/// Room that the gutter of a diagnostic takes: ` 12 | `.
const gutter_width = 6;

/// `sql` as a diagnostic shows it: when a line is wider than `width`, the space before each
/// clause of the outer statement (FROM, JOIN, WHERE, GROUP BY, ...) becomes a newline. The length
/// stays the same, so the byte offsets of labels still point at the same text.
fn displaySource(arena: Allocator, tree: *const parser_api.Tree, sql: []const u8, width: usize) Allocator.Error![]const u8 {
    if (width == 0) return sql;
    var widest: usize = 0;
    var lines = std.mem.splitScalar(u8, sql, '\n');
    while (lines.next()) |line| widest = @max(widest, codePoints(line));
    if (widest + gutter_width <= width) return sql;

    const out = try arena.dupe(u8, sql);
    var depth: usize = 0;
    var previous: []const u8 = "";
    for (tree.nodes) |node| {
        if (node.kind != .token or node.missing or node.start == node.end) continue;
        if (node.isToken(.open_par)) depth += 1;
        if (node.isToken(.close_par)) depth -|= 1;
        const word = sql[node.start..node.end];
        defer previous = word;
        if (depth != 0 or node.start == 0 or out[node.start - 1] != ' ') continue;
        // LEFT(...) is a function.
        if (node.end < sql.len and sql[node.end] == '(') continue;
        if (breaksBefore(word, previous)) out[node.start - 1] = '\n';
    }
    return out;
}

/// True when a line of a long statement starts at `word`, which follows `previous`.
fn breaksBefore(word: []const u8, previous: []const u8) bool {
    const clauses = [_][]const u8{ "FROM", "WHERE", "GROUP", "HAVING", "WINDOW", "ORDER", "LIMIT", "UNION", "SET", "VALUES" };
    for (clauses) |clause| {
        if (std.ascii.eqlIgnoreCase(word, clause)) return true;
    }
    const join_starts = [_][]const u8{ "JOIN", "STRAIGHT_JOIN", "LEFT", "RIGHT", "INNER", "CROSS", "NATURAL" };
    // The words that a join can start with, unless they continue one: LEFT JOIN, NATURAL LEFT JOIN.
    const join_words = [_][]const u8{ "LEFT", "RIGHT", "INNER", "CROSS", "OUTER", "NATURAL" };
    for (join_starts) |start| {
        if (!std.ascii.eqlIgnoreCase(word, start)) continue;
        for (join_words) |w| {
            if (std.ascii.eqlIgnoreCase(previous, w)) return false;
        }
        return true;
    }
    return false;
}

/// An error in the statement being typed. The offsets are into the text that was checked.
pub const Problem = struct {
    /// Byte offsets of the offending text, end exclusive.
    start: usize,
    end: usize,
    /// Owned by the caller. The parser's message, such as `"FROM" is not valid at this position`.
    message: []u8,
};

/// A statement of a text, as byte offsets, end exclusive.
const Span = struct { start: usize, end: usize };

/// The statement of `text` that holds `cursor`. A statement ends at the delimiter, or at a backslash
/// command that follows other words, such as `\G`. Null when the statement is a client command,
/// such as `DELIMITER $$`, which is not SQL.
fn statementAt(text: []const u8, cursor: usize, options: SqlLexer.Options) ?Span {
    var start: usize = 0;
    // True until the statement has a token other than whitespace or a comment.
    var first = true;
    var lexer = SqlLexer.Lexer.init(text, options);
    while (lexer.next()) |tok| {
        switch (tok.kind) {
            .whitespace, .comment => continue,
            .delimiter => {
                if (tok.start >= cursor) return .{ .start = start, .end = tok.start };
                start = tok.end;
                first = true;
            },
            .client_command => {
                if (first) return null;
                if (tok.start >= cursor) return .{ .start = start, .end = tok.start };
                start = tok.end;
                first = true;
            },
            else => first = false,
        }
    }
    return .{ .start = start, .end = text.len };
}

fn codePoints(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Runs on the warm-up thread. It has its own parser, and the allocator is thread-safe.
fn warmUp() void {
    var handle = Parser.init(std.heap.smp_allocator, default_version, .{}) catch return;
    defer handle.deinit();
    const errors = handle.check(warm_up_sql) catch return;
    handle.freeErrors(errors);
}

test "server versions map to MySQL version numbers" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 80403), versionNumber("8.4.3"));
    try testing.expectEqual(@as(u32, 50744), versionNumber("5.7.44-log"));
    try testing.expectEqual(@as(u32, 80036), versionNumber("8.0.36-0ubuntu0.22.04.1"));
    try testing.expectEqual(@as(u32, 80400), versionNumber("8.4"));
    try testing.expectEqual(default_version, versionNumber(""));
    try testing.expectEqual(default_version, versionNumber("unknown"));
}

test "MariaDB servers map to the closest MySQL version" {
    const testing = std.testing;
    try testing.expectEqual(mariadb_version, versionNumber("10.11.6-MariaDB"));
    try testing.expectEqual(mariadb_version, versionNumber("5.5.5-10.11.6-MariaDB-ubu2204"));
    try testing.expectEqual(mariadb_version, versionNumber("10.2.0-MariaDB"));
    try testing.expectEqual(mariadb_old_version, versionNumber("10.1.48-MariaDB"));
    try testing.expectEqual(mariadb_old_version, versionNumber("5.5.68-MariaDB"));
}

test "sql_mode names set the parser and lexer flags, ignoring case and unknown names" {
    const testing = std.testing;
    const mode = sqlModeFromText("STRICT_TRANS_TABLES, ansi_quotes ,NO_BACKSLASH_ESCAPES,NOSUCH");
    try testing.expect(mode.ansi_quotes);
    try testing.expect(mode.no_backslash_escapes);
    try testing.expect(!mode.pipes_as_concat);
    try testing.expect(!mode.high_not_precedence);

    const ansi = sqlModeFromText("ANSI");
    try testing.expect(ansi.ansi_quotes and ansi.pipes_as_concat and ansi.ignore_space);
    try testing.expect(!ansi.no_backslash_escapes);

    const none = sqlModeFromText("");
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(none)));
}

test "a disabled syntax has no parser, but still keeps the lexer options" {
    var syntax = Syntax.init(std.testing.allocator, false);
    defer syntax.deinit();
    try std.testing.expect(syntax.parser() == null);
    try std.testing.expect(!syntax.lexer.ansi_quotes);
}

test "an enabled syntax builds its parser after the warm-up" {
    var syntax = Syntax.init(std.testing.allocator, true);
    defer syntax.deinit();
    const handle = syntax.parser() orelse return error.TestUnexpectedResult;
    const errors = try handle.check("SELECT 1");
    defer handle.freeErrors(errors);
    try std.testing.expectEqual(@as(usize, 0), errors.len);
}

test "the parser follows the version and sql_mode it is given" {
    var syntax = Syntax.init(std.testing.allocator, true);
    defer syntax.deinit();
    const handle = syntax.parser() orelse return error.TestUnexpectedResult;
    syntax.version = 50744;
    handle.setVersion(syntax.version);
    const errors = try handle.check("WITH c AS (SELECT 1) SELECT * FROM c");
    defer handle.freeErrors(errors);
    try std.testing.expect(errors.len > 0);
}

fn expectProblem(text: []const u8, cursor: usize, expected_start: ?usize, expected_text: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    const found = try syntax.firstError(allocator, text, cursor, ";");
    if (found) |problem| {
        defer allocator.free(problem.message);
        const want_start = expected_start orelse {
            std.debug.print("expected no error for: {s}\n  got: {s}\n", .{ text, problem.message });
            return error.UnexpectedProblem;
        };
        try std.testing.expectEqual(want_start, problem.start);
        try std.testing.expectEqualStrings(expected_text.?, text[problem.start..problem.end]);
    } else if (expected_start != null) {
        std.debug.print("expected an error for: {s}\n", .{text});
        return error.ExpectedProblem;
    }
}

test "an error that reaches the end of the typed text is not reported" {
    // The statement is unfinished, and so is the string, so the user is still typing.
    try expectProblem("SELECT a FROM t WHERE", 22, null, null);
    try expectProblem("SELECT a FROM t WHERE   ", 25, null, null);
    try expectProblem("SELECT 'abc", 11, null, null);
    try expectProblem("SELECT a FROM t FROM", 21, null, null);
}

test "a space after an error finishes it, so the error is reported" {
    try expectProblem("SELECT a FROM t FROM ", 22, 16, "FROM");
}

test "an error before the end of the typed text is reported where it is" {
    // The second FROM is not expected, and more text follows it.
    try expectProblem("SELECT a FROM t FROM x", 22, 16, "FROM");
}

test "only the statement that holds the cursor is checked" {
    const text = "SELECT 1; SELECT a FROM t FROM x; SELECT 2";
    try expectProblem(text, 3, null, null);
    try expectProblem(text, 25, 26, "FROM");
    try expectProblem(text, 40, null, null);
}

test "client commands and backslash commands at the end of a statement are not SQL" {
    try expectProblem("DELIMITER $$", 13, null, null);
    try expectProblem("SELECT * FROM t \\G", 19, null, null);
    try expectProblem("SELECT a FROM t FROM \\G", 24, null, null);
}

test "a statement of only whitespace or comments has nothing to report" {
    try expectProblem("   ", 3, null, null);
    try expectProblem("-- just a note", 14, null, null);
}

test "an error from a line that continues the statement is reported in the whole text" {
    const text = "SELECT a\nFROM t FROM x";
    try expectProblem(text, text.len, 16, "FROM");
}

test "a disabled syntax reports nothing" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, false);
    defer syntax.deinit();
    try std.testing.expect((try syntax.firstError(allocator, "SELECT a FROM t FROM x", 22, ";")) == null);
}

test "a server syntax error is followed by the statement, with the parser's message under the text" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try syntax.explainError(&out.writer, "SELECT a\nFROM t FROM x", Syntax.parse_error_code, "You have an error in your SQL syntax", null, .{});
    try std.testing.expectEqualStrings(
        \\ --> query:2:8
        \\  |
        \\2 | FROM t FROM x
        \\  |        ^^^^ "FROM" is not valid at this position, expecting SEMICOLON
        \\
    , out.written());
}

test "an EXPLAIN result is drawn on its statement, and DESCRIBE of a table is not" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const plan_text = "-> Table scan on t  (cost=1 rows=3) (actual time=0.01..0.02 rows=3 loops=1)";
    const sql = "EXPLAIN ANALYZE SELECT * FROM t";
    try std.testing.expect(Syntax.mayBeExplain(sql));
    try syntax.annotatePlan(&out.writer, sql, &.{"EXPLAIN"}, &.{&.{plan_text}}, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "table scan · 3 rows · 0.02 ms") != null);

    out.clearRetainingCapacity();
    try syntax.annotatePlan(&out.writer, "DESCRIBE t", &.{ "Field", "Type" }, &.{&.{ "id", "int" }}, .{});
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(!Syntax.mayBeExplain("SELECT 1"));
}

test "a long statement is broken at its outer clauses, and keeps its length" {
    const allocator = std.testing.allocator;
    var p = try Parser.init(allocator, default_version, .{});
    defer p.deinit();
    const sql = "SELECT LEFT(name, 2) FROM users u LEFT JOIN (SELECT 1 AS id FROM t WHERE a = 1) d ON d.id = u.id WHERE u.id > 1 ORDER BY 1";
    var tree = try p.parse(sql);
    defer tree.deinit(allocator);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(sql, try displaySource(arena.allocator(), &tree, sql, 0));
    try std.testing.expectEqualStrings(sql, try displaySource(arena.allocator(), &tree, sql, 400));
    const shown = try displaySource(arena.allocator(), &tree, sql, 60);
    try std.testing.expectEqual(sql.len, shown.len);
    try std.testing.expectEqualStrings(
        \\SELECT LEFT(name, 2)
        \\FROM users u
        \\LEFT JOIN (SELECT 1 AS id FROM t WHERE a = 1) d ON d.id = u.id
        \\WHERE u.id > 1
        \\ORDER BY 1
    , shown);
}

test "a valid statement prints nothing, and so does a disabled syntax" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try syntax.explainError(&out.writer, "SELECT a FROM t", Syntax.parse_error_code, "", null, .{});
    try std.testing.expectEqualStrings("", out.written());

    var off = Syntax.init(allocator, false);
    defer off.deinit();
    try off.explainError(&out.writer, "SELECT a FROM t FROM x", Syntax.parse_error_code, "", null, .{});
    try std.testing.expectEqualStrings("", out.written());
}
