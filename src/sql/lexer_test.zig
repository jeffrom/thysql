//! Table-driven tests for the SQL lexer, and a check that it finds the same statement
//! boundaries as the batch scanner.

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Options = @import("lexer.zig").Options;
const Kind = @import("lexer.zig").Kind;
const Token = @import("lexer.zig").Token;
const Batch = @import("../batch.zig");

/// One expected token. Whitespace is not listed.
const Expect = struct {
    kind: Kind,
    text: []const u8,
    unterminated: bool = false,
};

const Case = struct {
    input: []const u8,
    expect: []const Expect,
    options: Options = .{},
};

const cases = [_]Case{
    .{
        .input = "select  1\n",
        .expect = &.{ .{ .kind = .reserved_keyword, .text = "select" }, .{ .kind = .number, .text = "1" } },
    },
    .{
        .input = "SeLeCt FrOm",
        .expect = &.{ .{ .kind = .reserved_keyword, .text = "SeLeCt" }, .{ .kind = .reserved_keyword, .text = "FrOm" } },
    },
    .{
        .input = "select 1 -- note\n2",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .comment, .text = "-- note" },
            .{ .kind = .number, .text = "2" },
        },
    },
    .{
        // Without a space, `--` is two minus signs.
        .input = "1--2",
        .expect = &.{
            .{ .kind = .number, .text = "1" },
            .{ .kind = .operator, .text = "-" },
            .{ .kind = .operator, .text = "-" },
            .{ .kind = .number, .text = "2" },
        },
    },
    .{
        .input = "select 1 --",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .comment, .text = "--" },
        },
    },
    .{
        .input = "--\tx",
        .expect = &.{.{ .kind = .comment, .text = "--\tx" }},
    },
    .{
        .input = "# note\nselect",
        .expect = &.{
            .{ .kind = .comment, .text = "# note" },
            .{ .kind = .reserved_keyword, .text = "select" },
        },
    },
    .{
        .input = "a /* b ; */ c",
        .expect = &.{
            .{ .kind = .identifier, .text = "a" },
            .{ .kind = .comment, .text = "/* b ; */" },
            .{ .kind = .identifier, .text = "c" },
        },
    },
    .{
        .input = "/* open ; select",
        .expect = &.{.{ .kind = .comment, .text = "/* open ; select", .unterminated = true }},
    },
    .{
        .input = "select /*+ NO_INDEX(t) */ 1",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .optimizer_hint, .text = "/*+ NO_INDEX(t) */" },
            .{ .kind = .number, .text = "1" },
        },
    },
    .{
        .input = "/*!40101 SET x = 1 */;",
        .expect = &.{
            .{ .kind = .version_comment_start, .text = "/*!40101" },
            .{ .kind = .reserved_keyword, .text = "SET" },
            .{ .kind = .identifier, .text = "x" },
            .{ .kind = .operator, .text = "=" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .version_comment_end, .text = "*/" },
            .{ .kind = .delimiter, .text = ";" },
        },
    },
    .{
        .input = "/*!80000 JSON_ARRAY() */",
        .expect = &.{
            .{ .kind = .version_comment_start, .text = "/*!80000" },
            .{ .kind = .function, .text = "JSON_ARRAY" },
            .{ .kind = .punctuation, .text = "(" },
            .{ .kind = .punctuation, .text = ")" },
            .{ .kind = .version_comment_end, .text = "*/" },
        },
    },
    .{
        .input = "/*! x */",
        .expect = &.{
            .{ .kind = .version_comment_start, .text = "/*!" },
            .{ .kind = .identifier, .text = "x" },
            .{ .kind = .version_comment_end, .text = "*/" },
        },
    },
    .{
        // A delimiter inside a version comment does not end the statement, as in the batch scanner.
        .input = "/*!40101 a;b */",
        .expect = &.{
            .{ .kind = .version_comment_start, .text = "/*!40101" },
            .{ .kind = .identifier, .text = "a" },
            .{ .kind = .punctuation, .text = ";" },
            .{ .kind = .identifier, .text = "b" },
            .{ .kind = .version_comment_end, .text = "*/" },
        },
    },
    .{
        .input = "'a''b' \"c\\\"d\" 'e\\'f'",
        .expect = &.{
            .{ .kind = .string, .text = "'a''b'" },
            .{ .kind = .string, .text = "\"c\\\"d\"" },
            .{ .kind = .string, .text = "'e\\'f'" },
        },
    },
    .{
        .input = "'a\\' 'b'",
        .options = .{ .no_backslash_escapes = true },
        .expect = &.{
            .{ .kind = .string, .text = "'a\\'" },
            .{ .kind = .string, .text = "'b'" },
        },
    },
    .{
        .input = "\"x y\" 'z'",
        .options = .{ .ansi_quotes = true },
        .expect = &.{
            .{ .kind = .quoted_identifier, .text = "\"x y\"" },
            .{ .kind = .string, .text = "'z'" },
        },
    },
    .{
        .input = "`a``b` c",
        .expect = &.{
            .{ .kind = .quoted_identifier, .text = "`a``b`" },
            .{ .kind = .identifier, .text = "c" },
        },
    },
    .{
        .input = "_utf8mb4'x' N'y' X'0f' B'01' n'z'",
        .expect = &.{
            .{ .kind = .string, .text = "_utf8mb4'x'" },
            .{ .kind = .string, .text = "N'y'" },
            .{ .kind = .string, .text = "X'0f'" },
            .{ .kind = .string, .text = "B'01'" },
            .{ .kind = .string, .text = "n'z'" },
        },
    },
    .{
        .input = "1 1.5 1e10 .5 1.5e-3 2E+4 0x0f 0b01",
        .expect = &.{
            .{ .kind = .number, .text = "1" },
            .{ .kind = .number, .text = "1.5" },
            .{ .kind = .number, .text = "1e10" },
            .{ .kind = .number, .text = ".5" },
            .{ .kind = .number, .text = "1.5e-3" },
            .{ .kind = .number, .text = "2E+4" },
            .{ .kind = .number, .text = "0x0f" },
            .{ .kind = .number, .text = "0b01" },
        },
    },
    .{
        // A word that starts with digits is an identifier, not a number.
        .input = "1abc 1e",
        .expect = &.{
            .{ .kind = .identifier, .text = "1abc" },
            .{ .kind = .identifier, .text = "1e" },
        },
    },
    .{
        .input = "db.tbl.col",
        .expect = &.{
            .{ .kind = .identifier, .text = "db" },
            .{ .kind = .dot, .text = "." },
            .{ .kind = .identifier, .text = "tbl" },
            .{ .kind = .dot, .text = "." },
            .{ .kind = .identifier, .text = "col" },
        },
    },
    .{
        .input = "$a_b é界 x$",
        .expect = &.{
            .{ .kind = .identifier, .text = "$a_b" },
            .{ .kind = .identifier, .text = "é界" },
            .{ .kind = .identifier, .text = "x$" },
        },
    },
    .{
        .input = "@x @'y z' @`w` @@session.sql_mode",
        .expect = &.{
            .{ .kind = .variable, .text = "@x" },
            .{ .kind = .variable, .text = "@'y z'" },
            .{ .kind = .variable, .text = "@`w`" },
            .{ .kind = .variable, .text = "@@session" },
            .{ .kind = .dot, .text = "." },
            .{ .kind = .identifier, .text = "sql_mode" },
        },
    },
    .{
        .input = "? ?",
        .expect = &.{
            .{ .kind = .placeholder, .text = "?" },
            .{ .kind = .placeholder, .text = "?" },
        },
    },
    .{
        .input = "a <=> b := c -> d ->> e << f >> g && h || i != j <> k <= l >= m",
        .expect = &.{
            .{ .kind = .identifier, .text = "a" },
            .{ .kind = .operator, .text = "<=>" },
            .{ .kind = .identifier, .text = "b" },
            .{ .kind = .operator, .text = ":=" },
            .{ .kind = .identifier, .text = "c" },
            .{ .kind = .operator, .text = "->" },
            .{ .kind = .identifier, .text = "d" },
            .{ .kind = .operator, .text = "->>" },
            .{ .kind = .identifier, .text = "e" },
            .{ .kind = .operator, .text = "<<" },
            .{ .kind = .identifier, .text = "f" },
            .{ .kind = .operator, .text = ">>" },
            .{ .kind = .identifier, .text = "g" },
            .{ .kind = .operator, .text = "&&" },
            .{ .kind = .identifier, .text = "h" },
            .{ .kind = .operator, .text = "||" },
            .{ .kind = .identifier, .text = "i" },
            .{ .kind = .operator, .text = "!=" },
            .{ .kind = .identifier, .text = "j" },
            .{ .kind = .operator, .text = "<>" },
            .{ .kind = .identifier, .text = "k" },
            .{ .kind = .operator, .text = "<=" },
            .{ .kind = .identifier, .text = "l" },
            .{ .kind = .operator, .text = ">=" },
            .{ .kind = .identifier, .text = "m" },
        },
    },
    .{
        .input = "select 1; select 2;",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .delimiter, .text = ";" },
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "2" },
            .{ .kind = .delimiter, .text = ";" },
        },
    },
    .{
        .input = "'a;b'",
        .expect = &.{.{ .kind = .string, .text = "'a;b'" }},
    },
    .{
        .input = "select a$$ select 'x$$'",
        .options = .{ .delimiter = "$$" },
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .identifier, .text = "a" },
            .{ .kind = .delimiter, .text = "$$" },
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .string, .text = "'x$$'" },
        },
    },
    .{
        .input = "count(*) COUNT (x) if(a) if",
        .expect = &.{
            .{ .kind = .function, .text = "count" },
            .{ .kind = .punctuation, .text = "(" },
            .{ .kind = .operator, .text = "*" },
            .{ .kind = .punctuation, .text = ")" },
            .{ .kind = .identifier, .text = "COUNT" },
            .{ .kind = .punctuation, .text = "(" },
            .{ .kind = .identifier, .text = "x" },
            .{ .kind = .punctuation, .text = ")" },
            .{ .kind = .function, .text = "if" },
            .{ .kind = .punctuation, .text = "(" },
            .{ .kind = .identifier, .text = "a" },
            .{ .kind = .punctuation, .text = ")" },
            .{ .kind = .reserved_keyword, .text = "if" },
        },
    },
    .{
        .input = "account",
        .expect = &.{.{ .kind = .keyword, .text = "account" }},
    },
    .{
        .input = "DELIMITER $$\nselect 1",
        .expect = &.{
            .{ .kind = .client_command, .text = "DELIMITER $$" },
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
        },
    },
    .{
        .input = "select 1\\G",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .client_command, .text = "\\G" },
        },
    },
    .{
        .input = "\\u db\nselect",
        .expect = &.{
            .{ .kind = .client_command, .text = "\\u db" },
            .{ .kind = .reserved_keyword, .text = "select" },
        },
    },
    .{
        .input = "select 1 \\c\nselect",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .client_command, .text = "\\c" },
            .{ .kind = .reserved_keyword, .text = "select" },
        },
    },
    .{
        // `DELIMITER` is only a client command at the start of a statement.
        .input = "select 1 delimiter",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .number, .text = "1" },
            .{ .kind = .identifier, .text = "delimiter" },
        },
    },
    .{
        .input = "source file.sql",
        .expect = &.{.{ .kind = .client_command, .text = "source file.sql" }},
    },
    .{
        .input = "select 'abc",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .string, .text = "'abc", .unterminated = true },
        },
    },
    .{
        .input = "select \"abc",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .string, .text = "\"abc", .unterminated = true },
        },
    },
    .{
        .input = "select `abc\n",
        .expect = &.{
            .{ .kind = .reserved_keyword, .text = "select" },
            .{ .kind = .quoted_identifier, .text = "`abc\n", .unterminated = true },
        },
    },
    .{
        // A doubled quote that is not closed is still inside the string.
        .input = "x 'it''s",
        .expect = &.{
            .{ .kind = .identifier, .text = "x" },
            .{ .kind = .string, .text = "'it''s", .unterminated = true },
        },
    },
    .{
        .input = "'a\\",
        .expect = &.{.{ .kind = .string, .text = "'a\\", .unterminated = true }},
    },
    .{
        .input = "/* x",
        .expect = &.{.{ .kind = .comment, .text = "/* x", .unterminated = true }},
    },
    .{
        .input = "/*+ x",
        .expect = &.{.{ .kind = .optimizer_hint, .text = "/*+ x", .unterminated = true }},
    },
    .{
        .input = "x @",
        .expect = &.{
            .{ .kind = .identifier, .text = "x" },
            .{ .kind = .unknown, .text = "@" },
        },
    },
};

fn expectTokens(index: usize, case: Case) !void {
    var lexer = Lexer.init(case.input, case.options);
    var seen: usize = 0;
    while (lexer.next()) |tok| {
        if (tok.kind == .whitespace) continue;
        if (seen >= case.expect.len) {
            std.debug.print("case {d} {s}: unexpected extra token {s}\n", .{ index, case.input, @tagName(tok.kind) });
            return error.TestUnexpectedResult;
        }
        const want = case.expect[seen];
        const text = case.input[tok.start..tok.end];
        if (tok.kind != want.kind or !std.mem.eql(u8, text, want.text) or tok.unterminated != want.unterminated) {
            std.debug.print(
                "case {d} {s}: token {d}: want {s} '{s}' unterminated={}, got {s} '{s}' unterminated={}\n",
                .{ index, case.input, seen, @tagName(want.kind), want.text, want.unterminated, @tagName(tok.kind), text, tok.unterminated },
            );
            return error.TestExpectedEqual;
        }
        seen += 1;
    }
    if (seen != case.expect.len) {
        std.debug.print("case {d} {s}: want {d} tokens, got {d}\n", .{ index, case.input, case.expect.len, seen });
        return error.TestExpectedEqual;
    }
}

test "lexer reads each table case" {
    for (cases, 0..) |case, index| {
        try expectTokens(index, case);
    }
}

test "lexer keeps positions when a token is unterminated at the end" {
    const text = "select 'x";
    var lexer = Lexer.init(text, .{});
    _ = lexer.next();
    _ = lexer.next();
    const last = lexer.next().?;
    try std.testing.expectEqual(text.len, last.end);
    try std.testing.expect(last.unterminated);
    try std.testing.expectEqual(@as(?Token, null), lexer.next());
}

/// The starts of the delimiter tokens, as the lexer finds them.
fn lexerBoundaries(gpa: std.mem.Allocator, input: []const u8, delimiter: []const u8) ![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(gpa);
    var lexer = Lexer.init(input, .{ .delimiter = delimiter });
    while (lexer.next()) |tok| {
        if (tok.kind == .delimiter) try starts.append(gpa, tok.start);
    }
    return starts.toOwnedSlice(gpa);
}

/// The starts of the statements that the batch scanner ends with its delimiter.
fn scannerBoundaries(gpa: std.mem.Allocator, input: []const u8, delimiter: []const u8) ![]usize {
    var scanner: Batch.Scanner = .{};
    defer scanner.deinit(gpa);
    try scanner.setDelimiter(delimiter);
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(gpa);
    for (input, 0..) |byte, i| {
        if (try scanner.feed(gpa, byte)) {
            try starts.append(gpa, i + 1 - delimiter.len);
            scanner.reset();
        }
    }
    return starts.toOwnedSlice(gpa);
}

test "lexer and batch scanner agree on statement boundaries" {
    const gpa = std.testing.allocator;
    const Boundary = struct { input: []const u8, delimiter: []const u8 };
    const boundaries = [_]Boundary{
        .{ .input = "select 'a;b'; select `x;y`; select \"c;d\";", .delimiter = ";" },
        .{ .input = "select 1 -- x;y\n; select 2 /* p;q */; select 3 /* unterminated", .delimiter = ";" },
        .{ .input = "select 'it''s;'; select 'a\\';b';", .delimiter = ";" },
        .{ .input = "select /*! 1; */ 2; select 3;", .delimiter = ";" },
        .{ .input = "create procedure p() begin select 'a$$'; end$$\nselect 1$$", .delimiter = "$$" },
        .{ .input = "select 1 // select 2//", .delimiter = "//" },
        .{ .input = "select 1 /* a ; b */ ; select `a;b`;", .delimiter = ";" },
        .{ .input = "select 1 # a;b\n; select 2 #x;\n; select 3 #", .delimiter = ";" },
        .{ .input = "select 1--1; select 2 --\n; select 3--x; 4 --\t;\n; select 5 --", .delimiter = ";" },
    };
    for (boundaries) |boundary| {
        const lexed = try lexerBoundaries(gpa, boundary.input, boundary.delimiter);
        defer gpa.free(lexed);
        const scanned = try scannerBoundaries(gpa, boundary.input, boundary.delimiter);
        defer gpa.free(scanned);
        std.testing.expectEqualSlices(usize, scanned, lexed) catch |err| {
            std.debug.print("boundaries differ for {s}\n", .{boundary.input});
            return err;
        };
    }
}
