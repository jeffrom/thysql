//! The interactive line editor: replete with the REPL's history file, its tab
//! completion of SQL keywords and names, and the MYSQL_HISTIGNORE filter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const replete = @import("replete");

const history_file = @import("history_file.zig");
const SqlCompletion = @import("sql_completion.zig");

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

        self.config = .{
            .prompt = "",
            .in = &self.input.interface,
            .out = out,
            .history = if (self.history) |*file| &file.history else null,
            .completer = .{ .context = names, .complete = completeWord },
            .highlighter = .{ .context = self, .highlight = highlightLine },
            .hinter = if (self.history) |*file| replete.Hinter{ .context = &file.history, .hint = replete.historyHinter } else null,
        };
        self.repl = try replete.Repl.init(allocator, &self.config);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.repl.deinit();
        if (self.history) |*file| file.deinit();
        self.spans.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Reads one line, shown after `prompt`. Ctrl-C and Ctrl-D come back as outcomes rather
    /// than errors. The terminal is in raw mode only while the line is being edited, so a
    /// query that runs afterwards gets the normal terminal settings.
    pub fn one(self: *Session, prompt: []const u8) !Outcome {
        self.repl.setPrompt(prompt);
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
    sqlSpans(session.gpa, line, &session.spans) catch {};
    return session.spans.items;
}

/// Appends spans for the SQL keywords (whole words, any case) and the quoted strings in `line`.
fn sqlSpans(gpa: Allocator, line: []const u8, spans: *std.ArrayList(replete.Span)) Allocator.Error!void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\'' or line[i] == '"') {
            const end = quotedEnd(line, i);
            try spans.append(gpa, .{ .start = i, .len = end - i, .style = .string });
            i = end;
        } else if (isSqlWordByte(line[i])) {
            var end = i;
            while (end < line.len and isSqlWordByte(line[end])) end += 1;
            if (isKeyword(line[i..end])) {
                try spans.append(gpa, .{ .start = i, .len = end - i, .style = .keyword });
            }
            i = end;
        } else {
            i += 1;
        }
    }
}

/// The end of the quoted string that starts at `start`: just past its closing quote, or the end of
/// the line when it is not closed. A doubled quote and a backslash-escaped byte stay inside it.
fn quotedEnd(line: []const u8, start: usize) usize {
    const quote = line[start];
    var i = start + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
        } else if (line[i] == quote) {
            if (i + 1 < line.len and line[i + 1] == quote) {
                i += 1;
            } else {
                return i + 1;
            }
        }
    }
    return line.len;
}

fn isKeyword(word: []const u8) bool {
    for (SqlCompletion.keywords) |keyword| {
        if (std.ascii.eqlIgnoreCase(keyword, word)) return true;
    }
    return false;
}

/// Offers the keywords and names that start with the word before the cursor. A word is
/// letters, digits, `_`, `$`, `.`, and bytes from 0x80 up, so `people.na` completes as one word.
fn completeWord(context: ?*anyopaque, line: []const u8, cursor: usize, candidates: *replete.Candidates) std.mem.Allocator.Error!usize {
    const names: *const SqlCompletion.Names = @ptrCast(@alignCast(context.?));
    var start = cursor;
    while (start > 0 and isSqlWordByte(line[start - 1])) {
        start -= 1;
    }
    const prefix = line[start..cursor];
    if (prefix.len == 0) {
        return cursor;
    }
    for (SqlCompletion.keywords) |keyword| {
        if (SqlCompletion.matches(keyword, prefix)) {
            try candidates.add(keyword);
        }
    }
    for (names.words.items) |name| {
        if (SqlCompletion.matches(name, prefix)) {
            try candidates.add(name);
        }
    }
    return start;
}

fn isSqlWordByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '.';
}

test "completion offers keywords and names for the word before the cursor" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.add("people");
    try names.add("orders");
    try names.add("people.name");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select peo";
    const start = try completeWord(&names, line, line.len, &candidates);
    try std.testing.expectEqual(@as(usize, 7), start);
    try std.testing.expectEqual(@as(usize, 2), candidates.list.items.len);
    try std.testing.expectEqualStrings("people", candidates.list.items[0].text);
    try std.testing.expectEqualStrings("people.name", candidates.list.items[1].text);
}

test "completion treats dots as part of the word" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.add("people.name");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select people.na";
    const start = try completeWord(&names, line, line.len, &candidates);
    try std.testing.expectEqual(@as(usize, 7), start);
    try std.testing.expectEqualStrings("people.name", candidates.list.items[0].text);
}

fn expectSpans(line: []const u8, expected: []const replete.Span) !void {
    var spans: std.ArrayList(replete.Span) = .empty;
    defer spans.deinit(std.testing.allocator);
    try sqlSpans(std.testing.allocator, line, &spans);
    try std.testing.expectEqualSlices(replete.Span, expected, spans.items);
}

test "highlighting marks keywords in any case and quoted strings" {
    try expectSpans("select 'a b' FROM t", &.{
        .{ .start = 0, .len = 6, .style = .keyword },
        .{ .start = 7, .len = 5, .style = .string },
        .{ .start = 13, .len = 4, .style = .keyword },
    });
}

test "highlighting skips keywords inside names and strings" {
    try expectSpans("selected 'select' \"and\" x_and", &.{
        .{ .start = 9, .len = 8, .style = .string },
        .{ .start = 18, .len = 5, .style = .string },
    });
}

test "a doubled quote or a backslash keeps a string going, and an open string runs to the end" {
    try expectSpans("'select''x' select", &.{
        .{ .start = 0, .len = 11, .style = .string },
        .{ .start = 12, .len = 6, .style = .keyword },
    });
    try expectSpans("'it\\'s' and", &.{
        .{ .start = 0, .len = 7, .style = .string },
        .{ .start = 8, .len = 3, .style = .keyword },
    });
    try expectSpans("x 'abc and", &.{
        .{ .start = 2, .len = 8, .style = .string },
    });
}

test "completion with an empty word offers nothing" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.add("people");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select ";
    const start = try completeWord(&names, line, line.len, &candidates);
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
