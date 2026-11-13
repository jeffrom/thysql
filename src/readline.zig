const std = @import("std");
const Allocator = std.mem.Allocator;

const isocline = @import("isocline.zig");
const SqlCompletion = @import("sql_completion.zig");

pub fn freeLine(ptr: ?*anyopaque) void {
    isocline.freeMemory(ptr);
}

/// Reads one line. The prompt is shown as written, with its `[` and `\` escaped for isocline.
pub fn one(allocator: Allocator, prompt: [:0]const u8) !?[:0]const u8 {
    const escaped = try escapeMarkup(allocator, prompt);
    defer allocator.free(escaped);
    return isocline.readline(escaped);
}

/// Escapes `text` for isocline's markup, where `[tag]` styles text. A `[` becomes `\[`, and a
/// `\` becomes `\\`, so both come out as written. Without this, a prompt such as `[\d]> `
/// would lose its brackets.
pub fn escapeMarkup(allocator: Allocator, text: []const u8) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (text) |byte| {
        if (byte == '[' or byte == '\\') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, byte);
    }
    return out.toOwnedSliceSentinel(allocator, 0);
}

/// Sets up history and tab completion. Completion offers the words in `names`,
/// which the caller owns and keeps loaded.
pub fn setup(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, names: *SqlCompletion.Names) void {
    isocline.setupHistory(allocator, io, env);
    isocline.disablePromptMarker();
    isocline.setDefaultCompleter(completeLine, names);
}

/// Completes the word before the cursor. A word is letters, digits, `_`, `$`, and `.`,
/// so `people.na` completes as one word.
fn completeLine(env: ?*isocline.CompletionEnv, prefix: [*c]const u8) callconv(.c) void {
    isocline.completeWord(env orelse return, prefix, completeWord, isSqlWordChar);
}

fn isSqlWordChar(s: [*c]const u8, len: c_long) callconv(.c) bool {
    if (s == null or len <= 0) {
        return false;
    }
    const byte = s[0];
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '.';
}

fn completeWord(env: ?*isocline.CompletionEnv, word: [*c]const u8) callconv(.c) void {
    const cenv = env orelse return;
    const arg = isocline.completionArg(cenv) orelse return;
    const names: *const SqlCompletion.Names = @ptrCast(@alignCast(arg));
    const prefix = std.mem.span(word);
    if (prefix.len == 0) {
        return;
    }
    for (SqlCompletion.keywords) |keyword| {
        if (SqlCompletion.matches(keyword, prefix)) {
            isocline.addCompletion(cenv, keyword);
        }
    }
    for (names.words.items) |name| {
        if (SqlCompletion.matches(name, prefix)) {
            isocline.addCompletion(cenv, name);
        }
    }
}

pub fn removeLastHistory() void {
    isocline.removeLastHistory();
}

/// Adds a statement to the history, unless `ignore` matches it.
pub fn addHistory(ignore: *const Ignore, entry: [:0]const u8) void {
    if (ignore.matches(entry)) {
        return;
    }
    isocline.addHistory(entry);
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

test "prompt markup escapes brackets and backslashes and leaves other text alone" {
    const escaped = try escapeMarkup(std.testing.allocator, "[\\d] \\_\\u> ");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("\\[\\\\d] \\\\_\\\\u> ", escaped);

    const plain = try escapeMarkup(std.testing.allocator, "root@host:3306/db> ");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("root@host:3306/db> ", plain);
}

test "history ignore with no variable keeps everything" {
    var ignore = try Ignore.init(std.testing.allocator, null);
    defer ignore.deinit();
    try std.testing.expect(!ignore.matches("select 'secret'"));
}
