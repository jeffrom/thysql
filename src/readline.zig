//! The interactive line editor: replete with the REPL's history file, its tab
//! context-aware completion of SQL keywords and names, and the MYSQL_HISTIGNORE filter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const replete = @import("replete");

const Batch = @import("batch.zig");
const history_file = @import("history_file.zig");
const ClientCommand = @import("client_command.zig");
const SqlCompletion = @import("sql_completion.zig");
const SqlContext = @import("sql/context.zig");
const SqlKeywords = @import("sql/keywords.zig");
const SqlLexer = @import("sql/lexer.zig");
const Syntax = @import("syntax.zig").Syntax;

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
    /// The lexer settings for the session's sql_mode, read by the highlighter and completion.
    syntax: *Syntax,
    /// The result of the last idle check of the line. The highlighter and the diagnostic read it.
    analysis: Analysis = .{},
    /// The SIGWINCH action that was installed before `setup`, restored by `deinit`.
    old_winch: std.posix.Sigaction = undefined,

    /// Sets up the line editor for the interactive client. Lines are read from stdin and
    /// written to `out`. Tab completes the names and keywords that fit the context of the cursor,
    /// from `names`, which the caller keeps loaded. `syntax` holds the sql_mode, which the caller keeps
    /// up to date. Free the result with `deinit`.
    pub fn setup(
        allocator: Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        out: *std.Io.Writer,
        names: *SqlCompletion.Names,
        syntax: *Syntax,
    ) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .gpa = allocator,
            .io = io,
            .stdout = out,
            .fd = std.Io.File.stdin().handle,
            .syntax = syntax,
        };
        // stdin is a terminal here, which cannot be read by position.
        self.input = std.Io.File.stdin().readerStreaming(io, &self.input_buffer);
        self.history = openHistory(allocator, io, env);
        errdefer if (self.history) |*file| file.deinit();

        self.completion = .{ .names = names, .syntax = syntax, .scratch = .init(allocator) };
        errdefer self.completion.scratch.deinit();
        self.config = .{
            .prompt = "",
            .in = &self.input.interface,
            .out = out,
            .history = if (self.history) |*file| &file.history else null,
            .completer = .{ .context = &self.completion, .complete = completeWord },
            .highlighter = .{ .context = self, .highlight = highlightLine },
            .hinter = .{ .context = self, .hint = hintLine },
            .diagnoser = .{ .context = self, .diagnose = diagnoseLine },
            .idle = .{ .context = self, .tick = idleTick, .delay_ms = idle_delay_ms },
        };
        self.repl = try replete.Repl.init(allocator, &self.config);
        // A resize interrupts the wait for input, and the next idle check redraws the line at its new width.
        const winch: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigwinch },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.WINCH, &winch, &self.old_winch);
        return self;
    }

    pub fn deinit(self: *Session) void {
        std.posix.sigaction(.WINCH, &self.old_winch, null);
        self.repl.deinit();
        self.completion.scratch.deinit();
        if (self.history) |*file| file.deinit();
        self.spans.deinit(self.gpa);
        self.joined.deinit(self.gpa);
        self.analysis.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Reads one line, shown after `prompt`. `pending` is the statement that the line continues,
    /// which the highlighter reads. Ctrl-C and Ctrl-D come back as outcomes rather than errors.
    /// The terminal is in raw mode only while the line is being edited, so a query that runs
    /// afterwards gets the normal terminal settings.
    pub fn one(self: *Session, prompt: []const u8, pending: *Batch.Scanner) !Outcome {
        self.repl.setPrompt(prompt);
        self.scanner = pending;
        self.completion.scanner = pending;
        // The last check was for the statement before this one, so it is not kept.
        self.analysis.clear(self.gpa);
        defer {
            self.scanner = null;
            self.completion.scanner = null;
        }
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

    /// Checks `line` with the statement it continues, and keeps the first error for `diagnoseLine`
    /// and the highlighter. The statement that holds the cursor is the one checked.
    fn analyze(self: *Session, line: []const u8, cursor: usize) !void {
        self.analysis.clear(self.gpa);
        self.analysis.valid = true;
        try self.analysis.line.appendSlice(self.gpa, line);
        self.analysis.cursor = cursor;

        const pending: []const u8 = if (self.scanner) |batch| batch.pendingQuery().sql else "";
        const delimiter: []const u8 = if (self.scanner) |batch| batch.delimiterText() else ";";
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        if (pending.len > 0) {
            try text.appendSlice(self.gpa, pending);
            try text.append(self.gpa, '\n');
        }
        const prefix = text.items.len;
        try text.appendSlice(self.gpa, line);

        const problem = (try self.syntax.firstError(self.gpa, text.items, prefix + cursor, delimiter)) orelse return;
        defer self.gpa.free(problem.message);
        self.analysis.message = try std.fmt.allocPrint(self.gpa, "syntax error: {s}", .{problem.message});
        if (problem.end > prefix) {
            self.analysis.start = problem.start -| prefix;
            self.analysis.end = problem.end - prefix;
        }
    }

    /// The bytes of `line` that the error covers, or null when the check was for another line, or
    /// the error is not in this line.
    fn errorSpan(self: *const Session, line: []const u8) ?struct { start: usize, end: usize } {
        if (!self.analysis.lineIs(line) or self.analysis.end <= self.analysis.start) return null;
        return .{ .start = self.analysis.start, .end = self.analysis.end };
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
    appendSpans(session.gpa, &session.joined, &session.spans, session.scanner, session.syntax.lexer, line) catch {};
    // The error goes last, so that it is drawn over the style of its token.
    if (session.errorSpan(line)) |span| {
        session.spans.append(session.gpa, .{ .start = span.start, .len = span.end - span.start, .style = .@"error" }) catch {};
    }
    return session.spans.items;
}

/// How long the line must be idle before it is checked for a syntax error, in milliseconds.
const idle_delay_ms = 200;

/// Set by the SIGWINCH handler when the terminal is resized.
var winch_requested = std.atomic.Value(bool).init(false);

fn handleSigwinch(_: std.posix.SIG) callconv(.c) void {
    winch_requested.store(true, .release);
}

/// The result of the last idle check of the line, and the error that it found, if any.
const Analysis = struct {
    /// Whether a check has run. The result is for `line` and `cursor` only.
    valid: bool = false,
    line: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    /// Owned. The message the line shows, such as `syntax error: "FROM" is not valid`, or null for none.
    message: ?[]u8 = null,
    /// The bytes of the line that the error covers, end exclusive. Both are 0 when the error is not in the line.
    start: usize = 0,
    end: usize = 0,

    /// True when the check was for `line`.
    fn lineIs(self: *const Analysis, line: []const u8) bool {
        return self.valid and std.mem.eql(u8, self.line.items, line);
    }

    fn clear(self: *Analysis, gpa: Allocator) void {
        self.valid = false;
        self.line.clearRetainingCapacity();
        self.cursor = 0;
        if (self.message) |text| gpa.free(text);
        self.message = null;
        self.start = 0;
        self.end = 0;
    }

    fn deinit(self: *Analysis, gpa: Allocator) void {
        self.clear(gpa);
        self.line.deinit(gpa);
    }
};

/// Runs when the input is idle, and when a signal interrupts the wait for input. It checks the line
/// unless the last check was for the same line and cursor. It asks for a redraw after a check, and
/// when the terminal was resized.
fn idleTick(context: ?*anyopaque, line: []const u8, cursor: usize) bool {
    const session: *Session = @ptrCast(@alignCast(context.?));
    const resized = winch_requested.swap(false, .acq_rel);
    if (!session.syntax.enabled) return resized;
    if (session.analysis.valid and session.analysis.cursor == cursor and session.analysis.lineIs(line)) return resized;
    session.analyze(line, cursor) catch return resized;
    return true;
}

/// The message for the line, from the last idle check. Nothing is shown while the line is changing.
fn diagnoseLine(context: ?*anyopaque, line: []const u8) ?[]const u8 {
    const session: *Session = @ptrCast(@alignCast(context.?));
    if (!session.analysis.lineIs(line)) return null;
    return session.analysis.message;
}

/// Appends spans for the SQL in `line`. The statement so far, which `scanner` holds, is lexed
/// before the line, so that a string or comment opened on an earlier line is styled here too.
/// Only the bytes of `line` get spans. `joined` is scratch space for the two parts.
fn appendSpans(
    gpa: Allocator,
    joined: *std.ArrayList(u8),
    spans: *std.ArrayList(replete.Span),
    scanner: ?*Batch.Scanner,
    lexer_options: SqlLexer.Options,
    line: []const u8,
) Allocator.Error!void {
    var options = lexer_options;
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
/// quoted names. It is reset at each Tab press, and the candidates last until the next one.
const Completion = struct {
    names: *const SqlCompletion.Names,
    /// The lexer settings come from here. Null in the tests, which use the defaults.
    syntax: ?*const Syntax = null,
    /// The statement being typed, while `Session.one` reads a line. It gives the context of the line.
    scanner: ?*Batch.Scanner = null,
    scratch: std.heap.ArenaAllocator,
};

/// Offers the names and keywords that fit the context of the cursor, as `sql/context.zig` reads
/// it, and returns where the word they replace starts. The word is letters, digits, `_`, `$`, and
/// bytes from 0x80 up. After a dot it is the part after the dot, and a backtick before the word
/// opens a quoted name, so the candidates are quoted too.
fn completeWord(context: ?*anyopaque, line: []const u8, cursor: usize, candidates: *replete.Candidates) std.mem.Allocator.Error!usize {
    const completion: *Completion = @ptrCast(@alignCast(context.?));
    _ = completion.scratch.reset(.retain_capacity);
    const scratch = completion.scratch.allocator();
    const expect = contextAt(scratch, completion, line, cursor) catch return cursor;

    var start = cursor;
    while (start > 0 and isSqlWordByte(line[start - 1])) {
        start -= 1;
    }
    if (qualifiedExpectation(expect)) {
        if (std.mem.lastIndexOfScalar(u8, line[start..cursor], '.')) |dot| start += dot + 1;
    }
    if (start > 0 and line[start - 1] == '`' and std.mem.count(u8, line[0 .. start - 1], "`") % 2 == 0) {
        start -= 1;
    }
    const prefix = line[start..cursor];
    var offers: Offers = .{
        .candidates = candidates,
        .scratch = scratch,
        .prefix = prefix,
        .quoted = prefix.len > 0 and prefix[0] == '`',
    };
    defer offers.seen.deinit(scratch);

    const names = completion.names;
    switch (expect) {
        .none, .variable => {},
        .client_command => try offerClientCommands(&offers),
        .keyword => |set| switch (set) {
            .statement => for (SqlContext.statement_keywords) |word| try offers.keyword(word, .keyword),
            .any => try offerEverything(&offers, names),
        },
        .database => for (names.databases.items) |name| try offers.name(name, .database, true),
        .table => |schema| try offerTables(&offers, names, schema),
        .column => |scope| {
            if (scope.len == 0) {
                try offerEverything(&offers, names);
            } else {
                try offerColumns(&offers, names, scope.slice());
            }
        },
        .column_of => |ref| {
            if (names.findTable(ref.schema, ref.table)) |table| {
                for (table.columns.items) |column| try offers.name(column, .column, false);
            }
        },
        .routine => for (names.routines.items) |routine| try offers.name(routine.name, .function, true),
    }
    return start;
}

/// The context of the cursor. The statement so far comes before the line, so that a clause on an
/// earlier line still counts, and the cursor moves with it.
fn contextAt(scratch: std.mem.Allocator, completion: *const Completion, line: []const u8, cursor: usize) !SqlContext.Expect {
    var text: std.ArrayList(u8) = .empty;
    var offset = cursor;
    var options: SqlLexer.Options = if (completion.syntax) |syntax| syntax.lexer else .{};
    if (completion.scanner) |batch| {
        options.delimiter = batch.delimiterText();
        const pending = batch.pendingQuery().sql;
        if (pending.len > 0) {
            try text.appendSlice(scratch, pending);
            try text.append(scratch, '\n');
            offset += text.items.len;
        }
    }
    try text.appendSlice(scratch, line);
    return SqlContext.expectAt(text.items, offset, options);
}

/// True when the word completed is a name after a dot, which replaces only the part after the dot.
fn qualifiedExpectation(expect: SqlContext.Expect) bool {
    return switch (expect) {
        .column_of => true,
        .table => |schema| schema != null,
        else => false,
    };
}

/// Collects the candidates for one Tab press. Each text is offered once, and only when it starts
/// with the prefix, ignoring case. Names are quoted when they need quotes or the word is quoted.
const Offers = struct {
    candidates: *replete.Candidates,
    scratch: std.mem.Allocator,
    /// The text typed before the cursor, which the candidates must start with.
    prefix: []const u8,
    /// True when the word starts with a backtick, so names are quoted and keywords are not offered.
    quoted: bool,
    /// The texts offered so far. The keys are allocated from `scratch`.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    /// Offers the name `text`, quoted when it needs quotes or the word is quoted.
    fn name(self: *Offers, text: []const u8, kind: replete.CandidateKind, space: bool) std.mem.Allocator.Error!void {
        const shown = if (self.quoted or SqlContext.needsQuoting(text)) try quoteIdentifier(self.scratch, text) else text;
        try self.offer(shown, kind, space);
    }

    /// Offers a keyword or a function name, which is never quoted. Nothing is offered inside quotes.
    fn keyword(self: *Offers, text: []const u8, kind: replete.CandidateKind) std.mem.Allocator.Error!void {
        if (self.quoted) return;
        try self.offer(text, kind, true);
    }

    fn offer(self: *Offers, text: []const u8, kind: replete.CandidateKind, space: bool) std.mem.Allocator.Error!void {
        if (!SqlCompletion.matches(text, self.prefix)) return;
        const found = try self.seen.getOrPut(self.scratch, text);
        if (found.found_existing) return;
        try self.candidates.addCandidate(.{ .text = text, .kind = kind, .space = space });
    }
};

/// The text of `name` as an identifier: in backticks when it needs them, with any backtick doubled.
fn quoteIdentifier(scratch: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!SqlContext.needsQuoting(name)) return name;
    var out: std.ArrayList(u8) = .empty;
    try out.append(scratch, '`');
    for (name) |byte| {
        if (byte == '`') try out.append(scratch, '`');
        try out.append(scratch, byte);
    }
    try out.append(scratch, '`');
    return out.toOwnedSlice(scratch);
}

/// Offers the tables of `schema`, or of the current database when there is no schema.
fn offerTables(offers: *Offers, names: *const SqlCompletion.Names, schema: ?[]const u8) std.mem.Allocator.Error!void {
    const wanted = schema orelse (names.database orelse return);
    for (names.tables.items) |table| {
        if (std.ascii.eqlIgnoreCase(table.schema, wanted)) try offers.name(table.name, .table, true);
    }
}

/// Offers the columns of the tables in `refs`, the functions, and the keywords that go in expressions.
fn offerColumns(offers: *Offers, names: *const SqlCompletion.Names, refs: []const SqlContext.TableRef) std.mem.Allocator.Error!void {
    for (refs) |ref| {
        if (names.findTable(ref.schema, ref.table)) |table| {
            for (table.columns.items) |column| try offers.name(column, .column, true);
        }
    }
    try offerFunctions(offers);
    for (SqlContext.expression_keywords) |word| try offers.keyword(word, .keyword);
}

fn offerFunctions(offers: *Offers) std.mem.Allocator.Error!void {
    for (SqlKeywords.functions) |name| {
        // A word that is both a keyword and a function, such as IF, is offered as the keyword.
        if (SqlKeywords.find(name) == null) try offers.keyword(name, .function);
    }
}

/// Offers every keyword, function and name, for a place where nothing narrower is known. A column
/// is offered by its name and as table.column.
fn offerEverything(offers: *Offers, names: *const SqlCompletion.Names) std.mem.Allocator.Error!void {
    for (SqlKeywords.keywords) |keyword| try offers.keyword(keyword.name, .keyword);
    try offerFunctions(offers);
    for (names.databases.items) |name| try offers.name(name, .database, true);
    for (names.tables.items) |table| try offers.name(table.name, .table, true);
    for (names.routines.items) |routine| try offers.name(routine.name, .function, true);
    for (names.tables.items) |table| {
        for (table.columns.items) |column| {
            try offers.name(column, .column, true);
            const qualified = try std.fmt.allocPrint(offers.scratch, "{s}.{s}", .{ table.name, column });
            try offers.offer(qualified, .column, true);
        }
    }
}

/// Offers the client commands by their letter, as `\c`, with the command's name listed beside it.
fn offerClientCommands(offers: *Offers) std.mem.Allocator.Error!void {
    for (ClientCommand.help_items) |item| {
        const letter = try offers.scratch.dupe(u8, &[_]u8{item.char});
        if (!SqlCompletion.matches(letter, offers.prefix)) continue;
        const shown = try std.fmt.allocPrint(offers.scratch, "\\{c}  {s}", .{ item.char, item.name });
        try offers.candidates.addCandidate(.{ .text = letter, .display = shown, .kind = .other, .space = false });
    }
}

fn isSqlWordByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte == '.';
}

/// The rest of the one candidate that fits the context at the end of the line, or null when there
/// is none or several. Used when no history entry matches.
fn contextHint(completion: *Completion, line: []const u8, cursor: usize) ?[]const u8 {
    if (cursor != line.len) return null;
    var candidates: replete.Candidates = .{ .gpa = completion.scratch.allocator() };
    const start = completeWord(completion, line, cursor, &candidates) catch return null;
    if (candidates.list.items.len != 1) return null;
    const text = candidates.list.items[0].text;
    const typed = line[start..cursor];
    if (text.len <= typed.len or !SqlCompletion.matches(text, typed)) return null;
    return text[typed.len..];
}

/// The hint for the line: the newest history entry that starts with it, as zsh does, else the
/// one context candidate from `contextHint`.
fn hintLine(context: ?*anyopaque, line: []const u8, cursor: usize) ?[]const u8 {
    const session: *Session = @ptrCast(@alignCast(context.?));
    if (session.history) |*file| {
        if (replete.historyHinter(&file.history, line, cursor)) |hint| return hint;
    }
    return contextHint(&session.completion, line, cursor);
}

/// A completion context over `names` for the tests. The caller frees its scratch arena.
fn testCompletion(allocator: std.mem.Allocator, names: *const SqlCompletion.Names) Completion {
    return .{ .names = names, .scratch = .init(allocator) };
}

/// Runs tab completion on `line` with the cursor at its end. Returns where the word starts. The
/// candidates use the scratch arena of `completion`, so it must outlive them.
fn completeLine(completion: *Completion, line: []const u8, candidates: *replete.Candidates) !usize {
    return completeWord(completion, line, line.len, candidates);
}

test "after FROM the tables of the current database are offered" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.addTable("app", "orders");
    try names.addTable("other", "people_archive");
    try names.setDatabase("app");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const start = try completeLine(&completion, "select * from peo", &candidates);
    try std.testing.expectEqual(@as(usize, 14), start);
    try std.testing.expectEqual(@as(usize, 1), candidates.list.items.len);
    try std.testing.expectEqualStrings("people", candidates.list.items[0].text);
    try std.testing.expectEqual(replete.CandidateKind.table, candidates.list.items[0].kind);
}

test "after a bare FROM the tables of the current database are all offered" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.addTable("app", "orders");
    try names.addTable("other", "ledger");
    try names.setDatabase("app");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select * from ", &candidates);
    try std.testing.expectEqual(@as(usize, 2), candidates.list.items.len);
    try std.testing.expectEqualStrings("people", candidates.list.items[0].text);
    try std.testing.expectEqualStrings("orders", candidates.list.items[1].text);
}

test "after a dot the columns of the table are offered, replacing only the part after the dot" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "name");
    try names.addColumn("app", "people", "id");
    try names.setDatabase("app");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const line = "select * from people p where p.na";
    const start = try completeLine(&completion, line, &candidates);
    try std.testing.expectEqual(line.len - 2, start);
    try std.testing.expectEqual(@as(usize, 1), candidates.list.items.len);
    try std.testing.expectEqualStrings("name", candidates.list.items[0].text);
    try std.testing.expect(!candidates.list.items[0].space);
}

test "columns of the tables in scope are offered after WHERE" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "name");
    try names.addTable("app", "orders");
    try names.addColumn("app", "orders", "total");
    try names.setDatabase("app");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select * from people, orders where tota", &candidates);
    try std.testing.expectEqual(@as(usize, 1), candidates.list.items.len);
    try std.testing.expectEqualStrings("total", candidates.list.items[0].text);
}

test "a word that is both a keyword and a function is offered once" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select if", &candidates);
    var ifs: usize = 0;
    var ifnull = false;
    for (candidates.list.items) |candidate| {
        if (std.mem.eql(u8, candidate.text, "IF")) ifs += 1;
        if (std.mem.eql(u8, candidate.text, "IFNULL")) ifnull = true;
    }
    try std.testing.expectEqual(@as(usize, 1), ifs);
    try std.testing.expect(ifnull);
}

test "at the start of a statement the statement keywords are offered" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "s", &candidates);
    try std.testing.expect(candidates.list.items.len >= 3);
    for (candidates.list.items) |candidate| {
        try std.testing.expectEqual(@as(u8, 'S'), candidate.text[0]);
    }
}

test "a name that needs quoting is offered in backticks, and a backtick starts the word" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "my table");
    try names.setDatabase("app");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const start = try completeLine(&completion, "select * from `my", &candidates);
    try std.testing.expectEqual(@as(usize, 14), start);
    try std.testing.expectEqual(@as(usize, 1), candidates.list.items.len);
    try std.testing.expectEqualStrings("`my table`", candidates.list.items[0].text);
}

test "a client command is offered by its letter after a backslash" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const start = try completeLine(&completion, "\\c", &candidates);
    try std.testing.expectEqual(@as(usize, 1), start);
    try std.testing.expectEqual(@as(usize, 1), candidates.list.items.len);
    try std.testing.expectEqualStrings("c", candidates.list.items[0].text);
    try std.testing.expect(!candidates.list.items[0].space);
}

test "inside a string nothing is offered" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.setDatabase("app");

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select 'pe", &candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.list.items.len);
}

test "the hint is the rest of the one context candidate, and nothing when there are several" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();
    try names.addTable("app", "people");
    try names.setDatabase("app");

    try std.testing.expectEqualStrings("ple", contextHint(&completion, "select * from peo", 17).?);
    try std.testing.expect(contextHint(&completion, "select * from people", 20) == null);
    try std.testing.expect(contextHint(&completion, "", 0) == null);
}

fn expectSpans(scanner: ?*Batch.Scanner, line: []const u8, expected: []const replete.Span) !void {
    const allocator = std.testing.allocator;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    var spans: std.ArrayList(replete.Span) = .empty;
    defer spans.deinit(allocator);
    try appendSpans(allocator, &joined, &spans, scanner, .{}, line);
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

test "with ANSI_QUOTES a double-quoted name is an identifier, as the sql_mode says" {
    const allocator = std.testing.allocator;
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    var spans: std.ArrayList(replete.Span) = .empty;
    defer spans.deinit(allocator);
    try appendSpans(allocator, &joined, &spans, null, .{ .ansi_quotes = true }, "\"a b\" x");
    try std.testing.expectEqualSlices(replete.Span, &.{
        .{ .start = 0, .len = 5, .style = .quoted_identifier },
        .{ .start = 6, .len = 1, .style = .identifier },
    }, spans.items);
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

/// A session with only the fields that the idle check reads. The caller frees the lists in it.
fn testSession(allocator: Allocator, syntax: *Syntax) Session {
    return .{ .gpa = allocator, .io = undefined, .stdout = undefined, .fd = -1, .syntax = syntax };
}

test "an idle check keeps the first error of the line, for the diagnostic and the highlighter" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var session = testSession(allocator, &syntax);
    defer session.analysis.deinit(allocator);
    defer session.spans.deinit(allocator);
    defer session.joined.deinit(allocator);

    const line = "SELECT a FROM t FROM x";
    try session.analyze(line, line.len);
    const message = diagnoseLine(&session, line) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, message, "syntax error: \"FROM\" is not valid"));
    // The line is styled, with the error last so that it is drawn over the token's own style.
    const spans = highlightLine(&session, line);
    try std.testing.expectEqual(replete.Style.@"error", spans[spans.len - 1].style);
    try std.testing.expectEqual(@as(usize, 16), spans[spans.len - 1].start);
    try std.testing.expectEqual(@as(usize, 4), spans[spans.len - 1].len);
    // Another line gets no diagnostic, because the check was for this one.
    try std.testing.expect(diagnoseLine(&session, "SELECT a FROM t") == null);
}

test "an idle check of a line that follows a statement in progress reports offsets in the line" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var scanner: Batch.Scanner = .{};
    defer scanner.deinit(allocator);
    try scanner.replacePending(allocator, "SELECT a");
    var session = testSession(allocator, &syntax);
    session.scanner = &scanner;
    defer session.analysis.deinit(allocator);
    defer session.spans.deinit(allocator);
    defer session.joined.deinit(allocator);

    const line = "FROM t FROM x";
    try session.analyze(line, line.len);
    try std.testing.expectEqual(@as(usize, 7), session.analysis.start);
    try std.testing.expectEqual(@as(usize, 11), session.analysis.end);
}

test "a line with no error has no diagnostic and no error style" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var session = testSession(allocator, &syntax);
    defer session.analysis.deinit(allocator);
    defer session.spans.deinit(allocator);
    defer session.joined.deinit(allocator);

    try session.analyze("SELECT a FROM t", 15);
    try std.testing.expect(session.analysis.valid);
    try std.testing.expect(diagnoseLine(&session, "SELECT a FROM t") == null);
    for (highlightLine(&session, "SELECT a FROM t")) |span| {
        try std.testing.expect(span.style != .@"error");
    }
}

test "the idle tick checks each line once, and asks for a redraw after a resize" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var session = testSession(allocator, &syntax);
    defer session.analysis.deinit(allocator);
    defer session.spans.deinit(allocator);
    defer session.joined.deinit(allocator);

    const line = "SELECT a FROM t FROM x";
    try std.testing.expect(idleTick(&session, line, line.len));
    try std.testing.expect(!idleTick(&session, line, line.len));

    winch_requested.store(true, .release);
    try std.testing.expect(idleTick(&session, line, line.len));
    try std.testing.expect(!idleTick(&session, line, line.len));
}

test "a disabled syntax never checks the line, and only redraws after a resize" {
    const allocator = std.testing.allocator;
    var syntax = Syntax.init(allocator, false);
    defer syntax.deinit();
    var session = testSession(allocator, &syntax);
    defer session.analysis.deinit(allocator);
    defer session.spans.deinit(allocator);
    defer session.joined.deinit(allocator);

    try std.testing.expect(!idleTick(&session, "SELECT a FROM t FROM x", 22));
    try std.testing.expect(!session.analysis.valid);
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
