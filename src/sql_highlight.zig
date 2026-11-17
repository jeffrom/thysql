//! SQL syntax highlighting outside the line editor: the style each token kind takes, shared
//! with the REPL's highlighter, and a writer that colours SQL in result values, such as the
//! DDL that SHOW CREATE TABLE returns.

const std = @import("std");
const replete = @import("replete");
const SqlLexer = @import("sql/lexer.zig");
const Unicode = @import("unicode.zig");

const reset = "\x1b[0m";

/// The style for a token of `kind`. Null for the text that is drawn plain.
pub fn styleOf(kind: SqlLexer.Kind) ?replete.Style {
    return switch (kind) {
        .reserved_keyword => .keyword,
        .keyword => .keyword_nonreserved,
        .function => .function,
        .identifier => .identifier,
        .quoted_identifier => .quoted_identifier,
        .string => .string,
        .number => .number,
        .comment, .optimizer_hint, .version_comment_start, .version_comment_end => .comment,
        .variable, .placeholder => .variable,
        .operator => .operator,
        .delimiter => .delimiter,
        .client_command => .client_command,
        .whitespace, .dot, .punctuation, .unknown => null,
    };
}

/// Colours SQL that the server returned. The lexer follows the session's sql_mode.
pub const Highlighter = struct {
    lexer: SqlLexer.Options,
    theme: replete.Theme = .{},

    /// Whether `sql` is a SHOW CREATE statement, the only kind whose result is coloured. Leading
    /// whitespace and comments are skipped.
    pub fn isShowCreate(sql: []const u8, options: SqlLexer.Options) bool {
        var lexer = SqlLexer.Lexer.init(sql, options);
        const words = [_][]const u8{ "SHOW", "CREATE" };
        var matched: usize = 0;
        while (lexer.next()) |tok| {
            switch (tok.kind) {
                .whitespace, .comment, .optimizer_hint, .version_comment_start, .version_comment_end => continue,
                else => {},
            }
            if (!std.ascii.eqlIgnoreCase(sql[tok.start..tok.end], words[matched])) return false;
            matched += 1;
            if (matched == words.len) return true;
        }
        return false;
    }

    /// Whether a column holds SQL to colour: the statement column of a SHOW CREATE result,
    /// such as `Create Table`, `Create View` or `CREATE USER for x@y`, or the
    /// `SQL Original Statement` of SHOW CREATE TRIGGER.
    pub fn isSqlColumn(name: []const u8) bool {
        return std.ascii.startsWithIgnoreCase(name, "create ") or
            std.ascii.eqlIgnoreCase(name, "SQL Original Statement");
    }

    /// Writes `sql` as vertical output does, with each token in its style. Every token's text is
    /// escaped as `Unicode.printVerticalValue` escapes it, so the value cannot drive the terminal.
    pub fn write(self: *const Highlighter, out: *std.Io.Writer, sql: []const u8) !void {
        var options = self.lexer;
        // The value is one statement, so a `;` in it is not a delimiter.
        options.delimiter = "";
        var lexer = SqlLexer.Lexer.init(sql, options);
        while (lexer.next()) |tok| {
            const text = sql[tok.start..tok.end];
            const sgr = if (styleOf(tok.kind)) |style| self.theme.sgr(style) else "";
            try out.writeAll(sgr);
            try Unicode.printVerticalValue(out, text);
            if (sgr.len > 0) try out.writeAll(reset);
        }
    }
};

test "isShowCreate matches SHOW CREATE statements only" {
    try std.testing.expect(Highlighter.isShowCreate("SHOW CREATE TABLE t", .{}));
    try std.testing.expect(Highlighter.isShowCreate("  show\n create view v", .{}));
    try std.testing.expect(Highlighter.isShowCreate("/* why */ SHOW -- x\nCREATE USER u", .{}));
    try std.testing.expect(!Highlighter.isShowCreate("SELECT 'a' AS `Create Table`", .{}));
    try std.testing.expect(!Highlighter.isShowCreate("SHOW TABLES", .{}));
    try std.testing.expect(!Highlighter.isShowCreate("SHOW", .{}));
    try std.testing.expect(!Highlighter.isShowCreate("", .{}));
}

test "isSqlColumn matches the statement columns of SHOW CREATE" {
    try std.testing.expect(Highlighter.isSqlColumn("Create Table"));
    try std.testing.expect(Highlighter.isSqlColumn("Create View"));
    try std.testing.expect(Highlighter.isSqlColumn("Create Procedure"));
    try std.testing.expect(Highlighter.isSqlColumn("CREATE USER for root@%"));
    try std.testing.expect(Highlighter.isSqlColumn("SQL Original Statement"));
    try std.testing.expect(!Highlighter.isSqlColumn("Table"));
    try std.testing.expect(!Highlighter.isSqlColumn("character_set_client"));
    try std.testing.expect(!Highlighter.isSqlColumn("Created"));
}

test "write colours keywords, names and strings, and resets after each" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const highlighter: Highlighter = .{ .lexer = .{} };
    try highlighter.write(&out, "CREATE TABLE `t` (\n  `a` DEFAULT 'x'\n);");
    const t: replete.Theme = .{};
    var expected: [512]u8 = undefined;
    const want = try std.fmt.bufPrint(&expected, "{s}CREATE{s} {s}TABLE{s} {s}`t`{s} (\n  {s}`a`{s} {s}DEFAULT{s} {s}'x'{s}\n);", .{
        t.keyword, reset, t.keyword, reset, t.quoted_identifier, reset, t.quoted_identifier, reset, t.keyword, reset, t.string, reset,
    });
    try std.testing.expectEqualStrings(want, out.buffered());
}

test "write escapes control bytes inside tokens" {
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const highlighter: Highlighter = .{ .lexer = .{} };
    try highlighter.write(&out, "COMMENT '\x1b[31m'");
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\x1b[31m") == null);
}
