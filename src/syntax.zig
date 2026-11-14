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

    fn joinWarmUp(self: *Syntax) void {
        if (self.warm_up) |thread| {
            thread.join();
            self.warm_up = null;
        }
    }
};

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
