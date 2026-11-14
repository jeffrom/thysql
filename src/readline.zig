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
const SqlParser = @import("sql/parser.zig");

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
    /// Mutable so that completion can load the tables of another database the first time it is
    /// named, with `Names.loadSchema`.
    names: *SqlCompletion.Names,
    /// The parser gives the candidates, and the lexer settings come from here. Null in the tests,
    /// which then use the lexer alone.
    syntax: ?*Syntax = null,
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
    const typed = try typedText(scratch, completion, line);
    var offers: Offers = .{
        .candidates = candidates,
        .scratch = scratch,
        .prefix = prefix,
        .quoted = prefix.len > 0 and prefix[0] == '`',
        .lower = lowerKeywords(typed.text, typed.offset + start, prefix, typed.options),
    };
    defer offers.seen.deinit(scratch);

    const names = completion.names;
    if (try offerParsed(&offers, completion, line, cursor, expect)) return start;
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
        .column_of => |ref| try offerColumnsOf(&offers, names, &.{ref}, false),
        .routine => try offerRoutines(&offers, names),
    }
    return start;
}

/// Offers what the parser expects at the cursor, from its candidates, and returns true. Keywords are
/// offered as they are. Names are offered for the kinds of rule that ask for them, and the lexer's
/// context says which ones: the table qualifier after `db.`, the table after a dot, and the tables in
/// scope. Returns false, so that the lexer's context is used alone, when the parser is off, gives no
/// candidates, or the cursor is in a string, a variable or a client command.
fn offerParsed(offers: *Offers, completion: *const Completion, line: []const u8, cursor: usize, expect: SqlContext.Expect) std.mem.Allocator.Error!bool {
    switch (expect) {
        .none, .variable, .client_command => return false,
        // After `name.` the lexer has resolved the name, alias or table, to a table. The parser
        // only sees a qualifier there and asks for `table_wild` (`t.*`) as well as a column, which
        // would offer tables after the dot and leave out the columns the lexer can name.
        .column_of => return false,
        else => {},
    }
    const syntax = completion.syntax orelse return false;
    const typed = try typedText(offers.scratch, completion, line);
    const list = (try syntax.candidates(typed.text, typed.offset + cursor, typed.options.delimiter)) orelse return false;
    defer syntax.freeCandidates(list);
    if (list.len == 0) return false;

    // The parser also lists tokens that are not words, such as NOT2 for `!`. Only the words of the
    // keyword and function tables are offered. The grammar has tokens of its own for some functions,
    // such as COUNT and SUM, which are not keywords.
    var wanted: Wanted = .{};
    var keywords: usize = 0;
    for (list) |candidate| switch (candidate.kind) {
        .keyword => if (parsedWordKind(candidate.text) != null) {
            keywords += 1;
        },
        .rule => if (candidate.rule) |rule| wanted.add(rule),
    };
    // Rules that name no kind of name, such as a generic identifier, tell nothing that the lexer
    // does not, so the lexer's context is used for them.
    if (keywords == 0 and !wanted.any()) return false;
    for (list) |candidate| {
        if (candidate.kind != .keyword) continue;
        const kind = parsedWordKind(candidate.text) orelse continue;
        // The parser frees its candidates when this returns, and offers keep their text until the next
        // Tab press, so a keyword is copied into the scratch arena.
        try offers.keyword(try offers.scratch.dupe(u8, candidate.text), kind);
    }

    const names = completion.names;
    if (wanted.databases) for (names.databases.items) |name| try offers.name(name, .database, true);
    if (wanted.tables) try offerTables(offers, names, switch (expect) {
        .table => |schema| schema,
        else => null,
    });
    if (wanted.routines) try offerRoutines(offers, names);
    if (wanted.functions) try offerFunctions(offers);
    if (wanted.columns) try offerExpectedColumns(offers, names, expect);
    return true;
}

/// How a keyword token from the parser is offered: as a keyword, as a function when only the
/// function table has it, or not at all when it is not a word, such as NOT2.
fn parsedWordKind(text: []const u8) ?replete.CandidateKind {
    if (SqlKeywords.find(text) != null) return .keyword;
    if (SqlKeywords.isFunction(text)) return .function;
    return null;
}

/// The kinds of name that the parser's rule candidates ask for.
const Wanted = struct {
    tables: bool = false,
    columns: bool = false,
    databases: bool = false,
    /// Stored procedures and functions, for CALL and friends.
    routines: bool = false,
    /// The built-in functions, for an expression.
    functions: bool = false,

    fn any(self: Wanted) bool {
        return self.tables or self.columns or self.databases or self.routines or self.functions;
    }

    fn add(self: *Wanted, rule: SqlParser.Rule) void {
        switch (rule) {
            .table_ref, .table_ref_with_wildcard, .filter_table_ref, .table_wild => self.tables = true,
            .column_ref, .column_internal_ref => self.columns = true,
            .schema_ref => self.databases = true,
            .function_ref => {
                self.functions = true;
                self.routines = true;
            },
            .procedure_ref => self.routines = true,
            else => {},
        }
    }
};

/// Offers the columns that the lexer's context names: those of the table after a dot, those of the
/// tables in scope, or else those of every table when no table is named yet.
fn offerExpectedColumns(offers: *Offers, names: *const SqlCompletion.Names, expect: SqlContext.Expect) std.mem.Allocator.Error!void {
    switch (expect) {
        .column_of => |ref| try offerColumnsOf(offers, names, &.{ref}, false),
        .column => |scope| {
            if (scope.len > 0) {
                try offerColumnsOf(offers, names, scope.slice(), true);
            } else {
                try offerAllColumns(offers, names);
            }
        },
        else => try offerAllColumns(offers, names),
    }
}

/// Offers the columns of every table that the names hold.
fn offerAllColumns(offers: *Offers, names: *const SqlCompletion.Names) std.mem.Allocator.Error!void {
    for (names.tables.items) |table| {
        for (table.columns.items) |column| try offers.name(column, .column, true);
    }
}

/// The context of the cursor. The statement so far comes before the line, so that a clause on an
/// earlier line still counts, and the cursor moves with it.
fn contextAt(scratch: std.mem.Allocator, completion: *const Completion, line: []const u8, cursor: usize) !SqlContext.Expect {
    const typed = try typedText(scratch, completion, line);
    return SqlContext.expectAt(typed.text, typed.offset + cursor, typed.options);
}

/// The statement typed so far, with the line after it, and the lexer settings for them.
const Typed = struct {
    text: []const u8,
    /// Where the line starts in `text`.
    offset: usize,
    options: SqlLexer.Options,
};

/// The statement typed so far, then a newline, then the line. `scratch` holds the text.
fn typedText(scratch: std.mem.Allocator, completion: *const Completion, line: []const u8) !Typed {
    var text: std.ArrayList(u8) = .empty;
    var options: SqlLexer.Options = if (completion.syntax) |syntax| syntax.lexer else .{};
    if (completion.scanner) |batch| {
        options.delimiter = batch.delimiterText();
        const pending = batch.pendingQuery().sql;
        if (pending.len > 0) {
            try text.appendSlice(scratch, pending);
            try text.append(scratch, '\n');
        }
    }
    const offset = text.items.len;
    try text.appendSlice(scratch, line);
    return .{ .text = text.items, .offset = offset, .options = options };
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
    /// True when keywords and functions are offered in lower case. See `lowerKeywords`.
    lower: bool = false,
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
        const shown = if (self.lower) try std.ascii.allocLowerString(self.scratch, text) else text;
        try self.offer(shown, kind, true);
    }

    fn offer(self: *Offers, text: []const u8, kind: replete.CandidateKind, space: bool) std.mem.Allocator.Error!void {
        if (!SqlCompletion.matches(text, self.prefix)) return;
        const found = try self.seen.getOrPut(self.scratch, text);
        if (found.found_existing) return;
        try self.candidates.addCandidate(.{ .text = text, .kind = kind, .space = space });
    }
};

/// Whether keywords are offered in lower case, following how the user writes them. A word being
/// typed decides by its own letters: all upper case gives upper case, and any lower-case letter
/// gives lower case, so `Sel` completes as `Select`. With no letters typed yet, the last reserved
/// keyword or function call before the word decides. Non-reserved keywords such as `name` are
/// often names, so they do not count. Upper case when nothing decides.
fn lowerKeywords(text: []const u8, word_start: usize, prefix: []const u8, options: SqlLexer.Options) bool {
    if (letterCase(prefix)) |case| return case == .lower;
    var lexer = SqlLexer.Lexer.init(text[0..word_start], options);
    var lower = false;
    while (lexer.next()) |token| {
        if (token.kind != .reserved_keyword and token.kind != .function) continue;
        if (letterCase(text[token.start..token.end])) |case| lower = case == .lower;
    }
    return lower;
}

/// The case of the letters of `word`: lower when any is lower case, upper when all are, and null
/// when it has none.
fn letterCase(word: []const u8) ?enum { lower, upper } {
    var upper = false;
    for (word) |byte| {
        if (std.ascii.isLower(byte)) return .lower;
        if (std.ascii.isUpper(byte)) upper = true;
    }
    return if (upper) .upper else null;
}

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

/// Offers the tables of `schema`, or of the current database when there is no schema. Another
/// database's tables are loaded from the server the first time they are asked for.
fn offerTables(offers: *Offers, names: *SqlCompletion.Names, schema: ?[]const u8) std.mem.Allocator.Error!void {
    const wanted = schema orelse (names.database orelse return);
    try names.loadSchema(wanted);
    for (names.tables.items) |table| {
        if (std.ascii.eqlIgnoreCase(table.schema, wanted)) try offers.name(table.name, .table, true);
    }
}

/// Offers the stored functions and procedures of the current database, which is where an
/// unqualified name finds them.
fn offerRoutines(offers: *Offers, names: *const SqlCompletion.Names) std.mem.Allocator.Error!void {
    const current = names.database orelse return;
    for (names.routines.items) |routine| {
        if (std.ascii.eqlIgnoreCase(routine.schema, current)) try offers.name(routine.name, .function, true);
    }
}

/// Offers the columns of the tables in `refs`, the functions, and the keywords that go in expressions.
fn offerColumns(offers: *Offers, names: *const SqlCompletion.Names, refs: []const SqlContext.TableRef) std.mem.Allocator.Error!void {
    try offerColumnsOf(offers, names, refs, true);
    try offerFunctions(offers);
    for (SqlContext.expression_keywords) |word| try offers.keyword(word, .keyword);
}

/// Offers the columns of the tables in `refs`. `space` says whether a space follows each column,
/// which is not so after a dot.
fn offerColumnsOf(offers: *Offers, names: *const SqlCompletion.Names, refs: []const SqlContext.TableRef, space: bool) std.mem.Allocator.Error!void {
    for (refs) |ref| {
        if (names.findTable(ref.schema, ref.table)) |table| {
            for (table.columns.items) |column| try offers.name(column, .column, space);
        }
    }
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
    // Other databases' tables, once loaded, need their `db.` and are not offered bare.
    if (names.database) |current| {
        for (names.tables.items) |table| {
            if (std.ascii.eqlIgnoreCase(table.schema, current)) try offers.name(table.name, .table, true);
        }
    }
    try offerRoutines(offers, names);
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
fn testCompletion(allocator: std.mem.Allocator, names: *SqlCompletion.Names) Completion {
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
    _ = try completeLine(&completion, "SELECT IF", &candidates);
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
    _ = try completeLine(&completion, "S", &candidates);
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

/// Counts the candidates of `kind` in `candidates`.
fn countKind(candidates: *const replete.Candidates, kind: replete.CandidateKind) usize {
    var count: usize = 0;
    for (candidates.list.items) |candidate| {
        if (candidate.kind == kind) count += 1;
    }
    return count;
}

/// True when `candidates` offers `text` as a candidate of `kind`.
fn offersAs(candidates: *const replete.Candidates, kind: replete.CandidateKind, text: []const u8) bool {
    for (candidates.list.items) |candidate| {
        if (candidate.kind == kind and std.mem.eql(u8, candidate.text, text)) return true;
    }
    return false;
}

test "with the parser on, a table after FROM is offered from the current database" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.addTable("app", "orders");
    try names.addTable("other", "ledger");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select * from ", &candidates);
    try std.testing.expectEqual(@as(usize, 2), countKind(&candidates, .table));
    try std.testing.expect(offersAs(&candidates, .table, "people"));
    try std.testing.expect(offersAs(&candidates, .table, "orders"));
    try std.testing.expect(!offersAs(&candidates, .table, "ledger"));
}

test "with the parser on, a table after a schema name comes from that schema" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.addTable("other", "ledger");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    const start = try completeLine(&completion, "select * from other.", &candidates);
    try std.testing.expectEqual(@as(usize, 20), start);
    try std.testing.expectEqual(@as(usize, 1), countKind(&candidates, .table));
    try std.testing.expectEqualStrings("ledger", candidates.list.items[0].text);
}

test "with the parser on, columns after WHERE are the columns of the tables in scope" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "name");
    try names.addColumn("app", "people", "nickname");
    try names.addTable("app", "orders");
    try names.addColumn("app", "orders", "total");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select * from people where n", &candidates);
    try std.testing.expectEqual(@as(usize, 2), countKind(&candidates, .column));
    try std.testing.expect(offersAs(&candidates, .column, "name"));
    try std.testing.expect(offersAs(&candidates, .column, "nickname"));
    try std.testing.expect(!offersAs(&candidates, .column, "total"));
}

test "with the parser on, a keyword comes from the parser, in the case typed" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "SEL", &candidates);
    var found = false;
    for (candidates.list.items) |candidate| {
        if (candidate.kind == .keyword and std.mem.eql(u8, candidate.text, "SELECT")) found = true;
    }
    try std.testing.expect(found);
}

test "with the parser on, a token that is not a word is not offered" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "name");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select * from people where n", &candidates);
    for (candidates.list.items) |candidate| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(candidate.text, "NOT2"));
    }
    try std.testing.expect(offersAs(&candidates, .keyword, "not"));
}

test "with the parser on, a database after USE comes from the server's names" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addDatabase("app");
    try names.addDatabase("archive");
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "use a", &candidates);
    try std.testing.expectEqual(@as(usize, 2), countKind(&candidates, .database));
    try std.testing.expectEqual(@as(usize, 0), countKind(&candidates, .table));
}

test "with the parser on, nothing is offered inside a string" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, true);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select 'pe", &candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.list.items.len);
}

/// Completes at the `|` in `marked`, with the parser on or off, over a `people` table with
/// columns `id`, `name` and `nickname`, and an `orders` table with `id` and `total`.
fn expectColumnsAtCursor(parser: bool, marked: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "id");
    try names.addColumn("app", "people", "name");
    try names.addColumn("app", "people", "nickname");
    try names.addTable("app", "orders");
    try names.addColumn("app", "orders", "id");
    try names.addColumn("app", "orders", "total");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, parser);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();

    const cursor = std.mem.indexOfScalar(u8, marked, '|').?;
    const line = try std.mem.concat(allocator, u8, &.{ marked[0..cursor], marked[cursor + 1 ..] });
    defer allocator.free(line);
    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeWord(&completion, line, cursor, &candidates);

    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(allocator);
    for (candidates.list.items) |candidate| try texts.append(allocator, candidate.text);
    std.mem.sort([]const u8, texts.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    if (texts.items.len != expected.len) {
        std.debug.print("at {s} (parser {}): got {d} candidates:", .{ marked, parser, texts.items.len });
        for (texts.items) |text| std.debug.print(" {s}", .{text});
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
    for (expected, texts.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "after table. in a select list only that table's columns are offered" {
    for ([_]bool{ false, true }) |parser| {
        try expectColumnsAtCursor(parser, "select people.|", &.{ "id", "name", "nickname" });
        try expectColumnsAtCursor(parser, "select people.n|", &.{ "name", "nickname" });
    }
}

test "after alias. before the FROM that defines the alias, that table's columns are offered" {
    for ([_]bool{ false, true }) |parser| {
        try expectColumnsAtCursor(parser, "select p.n| from people p;", &.{ "name", "nickname" });
        try expectColumnsAtCursor(parser, "select p.| from people p", &.{ "id", "name", "nickname" });
        try expectColumnsAtCursor(parser, "select o.t|, p.name from people p join orders o on o.id = p.id", &.{"total"});
    }
}

/// Completes the end of `line`, with the parser on or off, and returns the texts offered.
fn completeTexts(allocator: std.mem.Allocator, parser: bool, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "People");
    try names.addColumn("app", "People", "Name");
    try names.setDatabase("app");
    var syntax = Syntax.init(allocator, parser);
    defer syntax.deinit();
    var completion = testCompletion(allocator, &names);
    completion.syntax = &syntax;
    defer completion.scratch.deinit();
    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, line, &candidates);
    for (candidates.list.items) |candidate| try out.append(allocator, try allocator.dupe(u8, candidate.text));
}

/// Expects `want` among the completions of `line`, with the parser on and off.
fn expectOffered(line: []const u8, want: []const u8) !void {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |parser| {
        var texts: std.ArrayList([]const u8) = .empty;
        defer {
            for (texts.items) |text| allocator.free(text);
            texts.deinit(allocator);
        }
        try completeTexts(allocator, parser, line, &texts);
        for (texts.items) |text| {
            if (std.mem.eql(u8, text, want)) break;
        } else {
            std.debug.print("at \"{s}\" (parser {}): {s} not offered among {d}:", .{ line, parser, want, texts.items.len });
            for (texts.items) |text| std.debug.print(" {s}", .{text});
            std.debug.print("\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

test "keywords are completed in the case of the word being typed" {
    try expectOffered("sel", "select");
    try expectOffered("SEL", "SELECT");
    try expectOffered("select * from People wh", "where");
    try expectOffered("SELECT * FROM People WH", "WHERE");
    try expectOffered("select * from People WH", "WHERE");
    try expectOffered("select co", "count");
    try expectOffered("SELECT CO", "COUNT");
}

test "with nothing typed, keywords follow the case of the last reserved keyword" {
    try expectOffered("select * from People ", "where");
    try expectOffered("SELECT * FROM People ", "WHERE");
    // `name` and `status` are non-reserved keywords, here column names, so they do not count.
    try expectOffered("SELECT name, status FROM People ", "WHERE");
    try expectOffered("", "SELECT");
}

test "names keep their own case whatever the case typed" {
    try expectOffered("select * from peo", "People");
    try expectOffered("SELECT * FROM PEO", "People");
    try expectOffered("select na", "Name");
}

test "bare tables and routines come from the current database only" {
    const allocator = std.testing.allocator;
    var names = SqlCompletion.Names.init(allocator);
    defer names.deinit();
    try names.addTable("app", "people");
    try names.addTable("other", "pending");
    try names.addRoutine("app", "app_proc");
    try names.addRoutine("other", "other_proc");
    try names.setDatabase("app");
    var completion = testCompletion(allocator, &names);
    defer completion.scratch.deinit();

    var candidates: replete.Candidates = .{ .gpa = allocator };
    defer candidates.deinit();
    _ = try completeLine(&completion, "select * from pe", &candidates);
    try std.testing.expect(offersAs(&candidates, .table, "people"));
    try std.testing.expect(!offersAs(&candidates, .table, "pending"));

    candidates.list.clearRetainingCapacity();
    _ = try completeLine(&completion, "call ", &candidates);
    try std.testing.expect(offersAs(&candidates, .function, "app_proc"));
    try std.testing.expect(!offersAs(&candidates, .function, "other_proc"));
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
