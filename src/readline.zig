//! The interactive line editor: replete with the REPL's history file, its tab
//! completion of SQL keywords and names, and the MYSQL_HISTIGNORE filter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const replete = @import("replete");

const Batch = @import("batch.zig");
const history_file = @import("history_file.zig");
const SqlCompletion = @import("sql_completion.zig");
const SqlKeywords = @import("sql/keywords.zig");
const SqlLexer = @import("sql/lexer.zig");

/// What `Session.one` read.
pub const Outcome = union(enum) {
    /// The line without its newline. The caller owns it, and frees it with the allocator
    /// that `setup` was given.
    line: [:0]u8,
    /// Ctrl-C. The line is dropped, and the caller shows a new prompt.
    cancelled,
    /// Ctrl-D on an empty line, or the end of input.
    eof,
};

/// The line editor for the interactive client. It is created once, by `setup`.
pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    /// Where replete writes the prompt and echoes the line. Also where a newline goes
    /// after each line, which replete leaves to its caller.
    stdout: *std.Io.Writer,
    /// The terminal to read lines from.
    fd: i32,
    input_buffer: [4096]u8 = undefined,
    input: std.Io.File.Reader = undefined,
    config: replete.ReplConfig = undefined,
    repl: replete.Repl = undefined,
    /// Null when there is no usable history file. The client then has no history.
    history: ?replete.FileHistory = null,
    /// The highlight spans of the line being drawn. The highlighter returns them.
    spans: std.ArrayList(replete.Span) = .empty,
    /// The statement being typed, while `one` reads a line. The highlighter lexes it with the line.
    scanner: ?*Batch.Scanner = null,
    /// Scratch space where the highlighter joins the statement so far and the line.
    joined: std.ArrayList(u8) = .empty,
    /// What tab completion reads. It is in the session, which does not move, so replete can keep its pointer.
    completion: Completion = undefined,

    /// Sets up the line editor for the interactive client. Lines are read from stdin and
    /// written to `out`. Tab completes the SQL keywords and the words in `names`, which the
    /// caller keeps loaded. Free the result with `deinit`.
    pub fn setup(
        allocator: Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        out: *std.Io.Writer,
        names: *SqlCompletion.Names,
    ) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .gpa = allocator,
            .io = io,
            .stdout = out,
            .fd = std.Io.File.stdin().handle,
        };
        // stdin is a terminal here, which cannot be read by position.
        self.input = std.Io.File.stdin().readerStreaming(io, &self.input_buffer);
        self.history = openHistory(allocator, io, env);
        errdefer if (self.history) |*file| file.deinit();

        self.completion = .{ .names = names, .scratch = .init(allocator) };
        errdefer self.completion.scratch.deinit();
        self.config = .{
            .prompt = "",
            .in = &self.input.interface,
            .out = out,
            .history = if (self.history) |*file| &file.history else null,
            .completer = .{ .context = &self.completion, .complete = completeWord },
            .highlighter = .{ .context = self, .highlight = highlightLine },
            .hinter = if (self.history) |*file| replete.Hinter{ .context = &file.history, .hint = replete.historyHinter } else null,
        };
        self.repl = try replete.Repl.init(allocator, &self.config);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.repl.deinit();
        self.completion.scratch.deinit();
        if (self.history) |*file| file.deinit();
        self.spans.deinit(self.gpa);
        self.joined.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Reads one line, shown after `prompt`. `pending` is the statement that the line continues,
    /// which the highlighter reads. Ctrl-C and Ctrl-D come back as outcomes rather than errors.
    /// The terminal is in raw mode only while the line is being edited, so a query that runs
    /// afterwards gets the normal terminal settings.
    pub fn one(self: *Session, prompt: []const u8, pending: *Batch.Scanner) !Outcome {
        self.repl.setPrompt(prompt);
        self.scanner = pending;
        defer self.scanner = null;
        const term = try replete.TermState.enable(self.fd);
        defer term.disable();

        const line = self.repl.readlineOwned(self.gpa) catch |err| switch (err) {
            error.Cancelled => {
                try self.endLine("^C\n");
                return .cancelled;
            },
            error.EndOfStream => {
                try self.endLine("\n");
                return .eof;
            },
            else => return err,
        };
        try self.endLine("\n");
        return .{ .line = line };
    }

    /// Adds an accepted statement to the history and appends it to the history file, unless
    /// `ignore` matches it. A file that cannot be written is not an error: the statement is
    /// still in this session's history.
    pub fn addHistory(self: *Session, ignore: *const Ignore, entry: []const u8) void {
        if (ignore.matches(entry)) return;
        if (self.history) |*file| {
            _ = file.add(self.io, entry) catch {};
        }
    }

    /// Ends the line that was just read, then flushes, since replete has left the cursor at its end.
    fn endLine(self: *Session, text: []const u8) !void {
        try self.stdout.writeAll(text);
        try self.stdout.flush();
    }
};

/// Loads the history file, after converting it from isocline's format. Failures leave the
/// client without history, and the client still starts.
fn openHistory(allocator: Allocator, io: std.Io, env: *const std.process.Environ.Map) ?replete.FileHistory {
    const path = (history_file.historyPath(allocator, env) catch return null) orelse return null;
    defer allocator.free(path);
    history_file.convertIsocline(allocator, io, path) catch {};
    return replete.FileHistory.open(allocator, io, path, history_file.options) catch null;
}

/// Styles the line for the highlighter. The spans stay valid until the next call. If they
/// cannot all be kept, the line is drawn with the ones that could be.
fn highlightLine(context: ?*anyopaque, line: []const u8) []const replete.Span {
    const session: *Session = @ptrCast(@alignCast(context.?));
    session.spans.clearRetainingCapacity();
    appendSpans(session.gpa, &session.joined, &session.spans, session.scanner, line) catch {};
    return session.spans.items;
}

/// Appends spans for the SQL in `line`. The statement so far, which `scanner` holds, is lexed
/// before the line, so that a string or comment opened on an earlier line is styled here too.
/// Only the bytes of `line` get spans. `joined` is scratch space for the two parts.
fn appendSpans(
    gpa: Allocator,
    joined: *std.ArrayList(u8),
    spans: *std.ArrayList(replete.Span),
    scanner: ?*Batch.Scanner,
    line: []const u8,
) Allocator.Error!void {
    var options: SqlLexer.Options = .{};
    var prefix: usize = 0;
    joined.clearRetainingCapacity();
    if (scanner) |batch| {
        options.delimiter = batch.delimiterText();
        const pending = batch.pendingQuery().sql;
        if (pending.len > 0) {
            try joined.appendSlice(gpa, pending);
            try joined.append(gpa, '\n');
            prefix = joined.items.len;
        }
    }
    try joined.appendSlice(gpa, line);

    var lexer = SqlLexer.Lexer.init(joined.items, options);
    while (lexer.next()) |tok| {
        const style = styleOf(tok.kind) orelse continue;
        if (tok.end <= prefix) continue;
        const start = @max(tok.start, prefix);
        try spans.append(gpa, .{ .start = start - prefix, .len = tok.end - start, .style = style });
    }
}

/// The style for a token of `kind`. Null for the text that is drawn plain.
fn styleOf(kind: SqlLexer.Kind) ?replete.Style {
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

/// What tab completion reads. `scratch` holds the strings that candidates point to, such as
/// `table.column`. It is reset at each Tab press, and the candidates last until the next one.
const Completion = struct {
    names: *const SqlCompletion.Names,
    scratch: std.heap.ArenaAllocator,
};

/// Offers the keywords and names that start with the word before the cursor. A word is
/// letters, digits, `_`, `$`, `.`, and bytes from 0x80 up, so `people.na` completes as one word.
fn completeWord(context: ?*anyopaque, line: []const u8, cursor: usize, candidates: *replete.Candidates) std.mem.Allocator.Error!usize {
    const completion: *Completion = @ptrCast(@alignCast(context.?));
    _ = completion.scratch.reset(.retain_capacity);
    const scratch = completion.scratch.allocator();
    const names = completion.names;
    var start = cursor;
    while (start > 0 and isSqlWordByte(line[start - 1])) {
        start -= 1;
    }
    const prefix = line[start..cursor];
    if (prefix.len == 0) {
        return cursor;
    }
    for (SqlKeywords.keywords) |keyword| {
        if (SqlCompletion.matches(keyword.name, prefix)) {
            try candidates.add(keyword.name);
        }
    }
    for (SqlKeywords.functions) |name| {
        // A word that is both a keyword and a function, such as IF, was offered above.
        if (SqlCompletion.matches(name, prefix) and SqlKeywords.find(name) == null) {
            try candidates.add(name);
        }
    }
    // Each name once. A column is offered by its name and as table.column, as in mysql.cc.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (names.databases.items) |name| {
        try offerName(scratch, &seen, candidates, name, prefix);
    }
    for (names.tables.items) |table| {
        try offerName(scratch, &seen, candidates, table.name, prefix);
    }
    for (names.routines.items) |routine| {
        try offerName(scratch, &seen, candidates, routine.name, prefix);
    }
    for (names.tables.items) |table| {
        for (table.columns.items) |column| {
            try offerName(scratch, &seen, candidates, column, prefix);
            const qualified = try std.fmt.allocPrint(scratch, "{s}.{s}", .{ table.name, column });
            try offerName(scratch, &seen, candidates, qualified, prefix);
        }
    }
    return start;
}

/// Offers `text` when it starts with `prefix` and has not been offered yet. `seen` holds the
/// names offered by this Tab press, and is allocated from `scratch`.
fn offerName(
    scratch: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    candidates: *replete.Candidates,
    text: []const u8,
    prefix: []const u8,
) std.mem.Allocator.Error!void {
    if (!SqlCompletion.matches(text, prefix)) return;
    const found = try seen.getOrPut(scratch, text);
    if (!found.found_existing) {
        try candidates.add(text);
    }
}

fn isSqlWordByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '.';
}

/// A completion context over `names` for the tests. The caller frees its scratch arena.
fn testCompletion(allocator: std.mem.Allocator, names: *const SqlCompletion.Names) Completion {
    return .{ .names = names, .scratch = .init(allocator) };
}

test "completion offers keywords and names for the word before the cursor" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.addTable("app", "orders");
    try names.addColumn("app", "people", "name");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select peo";
    const start = try completeWord(&completion, line, line.len, &candidates);
    try std.testing.expectEqual(@as(usize, 7), start);
    try std.testing.expectEqual(@as(usize, 2), candidates.list.items.len);
    try std.testing.expectEqualStrings("people", candidates.list.items[0].text);
    try std.testing.expectEqualStrings("people.name", candidates.list.items[1].text);
}

test "completion offers SQL keywords and functions once each" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "if";
    _ = try completeWord(&completion, line, line.len, &candidates);
    var ifs: usize = 0;
    var ifnull = false;
    for (candidates.list.items) |candidate| {
        if (std.mem.eql(u8, candidate.text, "IF")) ifs += 1;
        if (std.mem.eql(u8, candidate.text, "IFNULL")) ifnull = true;
    }
    try std.testing.expectEqual(@as(usize, 1), ifs);
    try std.testing.expect(ifnull);
}

test "completion treats dots as part of the word" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "name");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select people.na";
    const start = try completeWord(&completion, line, line.len, &candidates);
    try std.testing.expectEqual(@as(usize, 7), start);
    try std.testing.expectEqualStrings("people.name", candidates.list.items[0].text);
}

fn expectSpans(scanner: ?*Batch.Scanner, line: []const u8, expected: []const replete.Span) !void {
    const allocator = std.testing.allocator;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    var spans: std.ArrayList(replete.Span) = .empty;
    defer spans.deinit(allocator);
    try appendSpans(allocator, &joined, &spans, scanner, line);
    try std.testing.expectEqualSlices(replete.Span, expected, spans.items);
}

test "highlighting marks keywords, functions, names and operators" {
    try expectSpans(null, "select a.b, count(*) from t -- x", &.{
        .{ .start = 0, .len = 6, .style = .keyword },
        .{ .start = 7, .len = 1, .style = .identifier },
        .{ .start = 9, .len = 1, .style = .identifier },
        .{ .start = 12, .len = 5, .style = .function },
        .{ .start = 18, .len = 1, .style = .operator },
        .{ .start = 21, .len = 4, .style = .keyword },
        .{ .start = 26, .len = 1, .style = .identifier },
        .{ .start = 28, .len = 4, .style = .comment },
    });
}

test "highlighting marks keywords in any case and quoted strings" {
    try expectSpans(null, "select 'a b' FROM t", &.{
        .{ .start = 0, .len = 6, .style = .keyword },
        .{ .start = 7, .len = 5, .style = .string },
        .{ .start = 13, .len = 4, .style = .keyword },
        .{ .start = 18, .len = 1, .style = .identifier },
    });
}

test "a non-reserved keyword has its own style" {
    try expectSpans(null, "account", &.{.{ .start = 0, .len = 7, .style = .keyword_nonreserved }});
}

test "highlighting skips keywords inside names and strings" {
    try expectSpans(null, "selected 'select' \"and\" x_and", &.{
        .{ .start = 0, .len = 8, .style = .identifier },
        .{ .start = 9, .len = 8, .style = .string },
        .{ .start = 18, .len = 5, .style = .string },
        .{ .start = 24, .len = 5, .style = .identifier },
    });
}

test "a doubled quote or a backslash keeps a string going, and an open string runs to the end" {
    try expectSpans(null, "'select''x' select", &.{
        .{ .start = 0, .len = 11, .style = .string },
        .{ .start = 12, .len = 6, .style = .keyword },
    });
    try expectSpans(null, "'it\\'s' and", &.{
        .{ .start = 0, .len = 7, .style = .string },
        .{ .start = 8, .len = 3, .style = .keyword },
    });
    try expectSpans(null, "x 'abc and", &.{
        .{ .start = 0, .len = 1, .style = .identifier },
        .{ .start = 2, .len = 8, .style = .string },
    });
}

test "a string opened on an earlier line is styled on the line that continues it" {
    const allocator = std.testing.allocator;
    var scanner: Batch.Scanner = .{};
    defer scanner.deinit(allocator);
    for ("select 'first\n") |byte| {
        _ = try scanner.feed(allocator, byte);
    }
    try expectSpans(&scanner, "second' from t", &.{
        .{ .start = 0, .len = 7, .style = .string },
        .{ .start = 8, .len = 4, .style = .keyword },
        .{ .start = 13, .len = 1, .style = .identifier },
    });
}

test "the statement delimiter from the scanner and client commands are styled" {
    const allocator = std.testing.allocator;
    var scanner: Batch.Scanner = .{};
    defer scanner.deinit(allocator);
    try scanner.setDelimiter("$$");
    try expectSpans(&scanner, "a$$", &.{
        .{ .start = 0, .len = 1, .style = .identifier },
        .{ .start = 1, .len = 2, .style = .delimiter },
    });
    try expectSpans(null, "DELIMITER $$", &.{.{ .start = 0, .len = 12, .style = .client_command }});
    try expectSpans(null, "\\G", &.{.{ .start = 0, .len = 2, .style = .client_command }});
}

test "completion with an empty word offers nothing" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select ";
    const start = try completeWord(&completion, line, line.len, &candidates);
    try std.testing.expectEqual(line.len, start);
    try std.testing.expectEqual(@as(usize, 0), candidates.list.items.len);
}

/// The statements that MYSQL_HISTIGNORE keeps out of the history. The value is a list of
/// glob patterns separated by colons. `*` matches any run of characters and `?` matches one.
/// Case is ignored. Empty patterns are skipped.
pub const Ignore = struct {
    allocator: Allocator,
    /// Owned copy of the variable. `patterns` point into it.
    text: []u8 = &.{},
    patterns: [][]const u8 = &.{},

    pub fn init(allocator: Allocator, value: ?[]const u8) !Ignore {
        var ignore: Ignore = .{ .allocator = allocator };
        errdefer ignore.deinit();
        const source = value orelse return ignore;

        ignore.text = try allocator.dupe(u8, source);
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);
        var parts = std.mem.splitScalar(u8, ignore.text, ':');
        while (parts.next()) |part| {
            if (part.len > 0) {
                try list.append(allocator, part);
            }
        }
        ignore.patterns = try list.toOwnedSlice(allocator);
        return ignore;
    }

    pub fn deinit(self: *Ignore) void {
        self.allocator.free(self.patterns);
        self.allocator.free(self.text);
        self.patterns = &.{};
        self.text = &.{};
    }

    pub fn matches(self: *const Ignore, text: []const u8) bool {
        for (self.patterns) |pattern| {
            if (globMatch(pattern, text)) {
                return true;
            }
        }
        return false;
    }
};

/// Matches `text` against a glob, ignoring ASCII case. `*` matches any run of
/// characters, including none, and `?` matches exactly one.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    // Where the last `*` was, and the text position it has consumed up to, for backtracking.
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_t = t;
            p += 1;
        } else if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(text[t]))) {
            p += 1;
            t += 1;
        } else if (star_p) |star| {
            star_t += 1;
            p = star + 1;
            t = star_t;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') {
        p += 1;
    }
    return p == pattern.len;
}

test "glob matches runs with star and single characters with question mark, ignoring case" {
    try std.testing.expect(globMatch("*PASSWORD*", "set password = 'x'"));
    try std.testing.expect(globMatch("*identified*", "CREATE USER u IDENTIFIED BY 'x'"));
    try std.testing.expect(globMatch("select?", "selectx"));
    try std.testing.expect(!globMatch("select?", "select"));
    try std.testing.expect(!globMatch("select?", "selectxy"));
    try std.testing.expect(globMatch("a*b*c", "axxbyyc"));
    try std.testing.expect(!globMatch("a*b*c", "axxbyy"));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(!globMatch("", "x"));
    try std.testing.expect(globMatch("abc", "ABC"));
}

test "history ignore splits patterns on colons and skips empty ones" {
    const allocator = std.testing.allocator;
    var ignore = try Ignore.init(allocator, "*secret*::drop ?able");
    defer ignore.deinit();

    try std.testing.expectEqual(@as(usize, 2), ignore.patterns.len);
    try std.testing.expect(ignore.matches("select 'secret'"));
    try std.testing.expect(ignore.matches("DROP table"));
    try std.testing.expect(!ignore.matches("select 1"));
}

test "history ignore with no variable keeps everything" {
    var ignore = try Ignore.init(std.testing.allocator, null);
    defer ignore.deinit();
    try std.testing.expect(!ignore.matches("select 'secret'"));
}
