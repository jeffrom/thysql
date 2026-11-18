//! The context of the cursor in SQL text: what the text at the cursor expects, such as a
//! table after FROM or a column after `alias.`, in the spirit of mycli's suggest_type. The text
//! is the statement typed so far, with the lines before the cursor's line included, so a
//! clause on an earlier line still counts. Tables named after the cursor count too, so that
//! `SELECT x.| FROM t x` resolves `x`.
//!
//! The scan is one pass over the lexer's tokens and allocates nothing. Names in the result are
//! slices of the text, with backticks or double quotes removed.
//!
//! `unknownQualifier` is the other check: it finds a column qualifier, such as `f` in `f.id`,
//! that names no table or alias of its statement, so that the mistake is reported as it is typed.

const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("lexer.zig").Token;
const LexOptions = @import("lexer.zig").Options;
const Kind = @import("lexer.zig").Kind;
const keywords = @import("keywords.zig");

/// The most tables that one statement can name in its scope. Later ones are not kept.
pub const max_scope = 16;

/// A table named by the statement, as `schema.table`, with its alias when it has one.
pub const TableRef = struct {
    /// The database, when the name is qualified. Null means the current database.
    schema: ?[]const u8 = null,
    table: []const u8,
    alias: ?[]const u8 = null,
    /// True for a derived table, `(SELECT ...) name`. `table` is then its alias, and it is not
    /// the name of a table in the database.
    derived: bool = false,
};

/// The tables that the statement names, in the order they are named.
pub const Scope = struct {
    items: [max_scope]TableRef = undefined,
    len: usize = 0,

    /// The tables, in order.
    pub fn slice(self: *const Scope) []const TableRef {
        return self.items[0..self.len];
    }

    /// Adds `ref`, and returns its index, or null when the scope is full.
    fn add(self: *Scope, ref: TableRef) ?usize {
        if (self.len == max_scope) return null;
        self.items[self.len] = ref;
        self.len += 1;
        return self.len - 1;
    }
};

/// The kinds of keyword that can be expected.
pub const Keywords = enum {
    /// The words that can start a statement.
    statement,
    /// No narrower set is known: any keyword, function or name.
    any,
};

/// What the text at the cursor expects.
pub const Expect = union(enum) {
    /// A keyword from the set that `Keywords` names.
    keyword: Keywords,
    /// A database name.
    database,
    /// A table name. `table` is the database typed before the dot, or null for the current
    /// database and no dot.
    table: ?[]const u8,
    /// A column of one of the tables in `scope`. The scope is empty when no table is named yet.
    column: Scope,
    /// A column of one table, typed after `table.` or `alias.`. The table is resolved against
    /// the statement's tables, so `schema` is set when the table is in another database.
    column_of: TableRef,
    /// A stored function or procedure.
    routine,
    /// A system or user variable, after `@@` or `@`.
    variable,
    /// A client command, after a backslash.
    client_command,
    /// Nothing is expected here, as inside a string or a comment.
    none,
};

/// The words that can start a statement, for `Keywords.statement`.
pub const statement_keywords = [_][]const u8{
    "ALTER",   "ANALYZE",  "BEGIN",     "CALL",     "COMMIT",     "CREATE",    "DEALLOCATE", "DELETE",
    "DESCRIBE", "DO",      "DROP",      "EXECUTE",  "EXPLAIN",    "GRANT",     "INSERT",     "KILL",
    "LOAD",    "LOCK",     "OPTIMIZE",  "PREPARE",  "RENAME",     "REPLACE",   "RESET",      "REVOKE",
    "ROLLBACK", "SAVEPOINT", "SELECT", "SET",      "SHOW",       "START",     "TABLE",      "TRUNCATE",
    "UNLOCK",  "UPDATE",   "USE",       "VALUES",   "WITH",
};

/// The keywords that can follow in an expression. They are offered with the column names.
pub const expression_keywords = [_][]const u8{
    "AND",   "BETWEEN", "CASE",  "DISTINCT", "ELSE", "EXISTS", "FALSE", "IN",
    "INTERVAL", "IS",   "LIKE",  "NOT",      "NULL", "OR",     "THEN",  "TRUE",
    "WHEN",  "XOR",
};

/// True when `name` must be quoted with backticks to be used as an identifier: it is empty, has a
/// byte other than a letter, digit, `_` or `$` (bytes from 0x80 up count as letters), is all
/// digits, or is a reserved word.
pub fn needsQuoting(name: []const u8) bool {
    if (name.len == 0) return true;
    var all_digits = true;
    for (name) |byte| {
        if (byte >= 0x80) {
            all_digits = false;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '$') return true;
        if (!std.ascii.isDigit(byte)) all_digits = false;
    }
    if (all_digits) return true;
    if (keywords.find(name)) |keyword| return keyword.reserved;
    return false;
}

/// Returns what the cursor expects in `text`. `cursor` is a byte offset into `text`. `options`
/// are the session's lexer settings. The result refers to `text`.
pub fn expectAt(text: []const u8, cursor: usize, options: LexOptions) Expect {
    var state: State = .{};
    var lexer = Lexer.init(text, options);
    while (lexer.next()) |tok| {
        switch (tok.kind) {
            .whitespace, .optimizer_hint, .version_comment_start, .version_comment_end => continue,
            .comment, .string => if (insideLiteral(tok, text, cursor)) return .none,
            else => {},
        }
        if (tok.kind == .comment) continue;
        if (tok.kind == .delimiter) {
            if (tok.start >= cursor) break;
            state.reset();
            continue;
        }
        if (tok.kind == .client_command) {
            if (tok.start >= cursor) break;
            if (cursor <= tok.end) return .client_command;
            state.reset();
            continue;
        }
        const sig = Sig.of(tok.kind, text[tok.start..tok.end]);
        if (tok.start >= cursor) {
            state.addAfter(sig);
            continue;
        }
        if (cursor <= tok.end) {
            if (tok.kind == .variable or (tok.kind == .unknown and sig.text[0] == '@')) return .variable;
            if (isPartialKind(tok.kind)) {
                state.partial = sig;
                continue;
            }
        }
        state.addBefore(sig);
    }
    return state.classify();
}

/// True when the cursor is inside the string or comment `tok`: after its start and before its end,
/// or at the end of the text when it is unterminated. A line comment that ends the text is still
/// open at its end, since it runs to the end of the line.
fn insideLiteral(tok: Token, text: []const u8, cursor: usize) bool {
    if (tok.start >= cursor) return false;
    if (cursor < tok.end) return true;
    if (cursor != tok.end) return false;
    if (tok.unterminated) return true;
    const line_comment = std.mem.startsWith(u8, text[tok.start..], "#") or std.mem.startsWith(u8, text[tok.start..], "--");
    return line_comment and tok.end == text.len and text[tok.end - 1] != '\n';
}

/// A token that the context looks at: its kind, and its text without any quotes.
const Sig = struct {
    kind: Kind,
    text: []const u8,

    fn of(kind: Kind, raw: []const u8) Sig {
        if (kind == .quoted_identifier and raw.len >= 2 and raw[raw.len - 1] == raw[0]) {
            return .{ .kind = kind, .text = raw[1 .. raw.len - 1] };
        }
        return .{ .kind = kind, .text = raw };
    }

    /// True for a keyword or function name spelled `word`, in any case.
    fn is(self: Sig, word: []const u8) bool {
        return isWordKind(self.kind) and std.ascii.eqlIgnoreCase(self.text, word);
    }

    /// True for the punctuation `text`, such as a comma.
    fn isPunct(self: Sig, text: []const u8) bool {
        return self.kind == .punctuation and std.mem.eql(u8, self.text, text);
    }
};

/// A word the lexer reads as a keyword, a function name, or a plain identifier.
fn isWordKind(kind: Kind) bool {
    return switch (kind) {
        .identifier, .keyword, .reserved_keyword, .function => true,
        else => false,
    };
}

/// A name, which may also be a non-reserved keyword, such as `ACCOUNT`.
fn isNameKind(kind: Kind) bool {
    return switch (kind) {
        .identifier, .keyword, .quoted_identifier => true,
        else => false,
    };
}

/// A token that the cursor can be in the middle of, so that it is the word being completed.
fn isPartialKind(kind: Kind) bool {
    return switch (kind) {
        .identifier, .keyword, .reserved_keyword, .function, .quoted_identifier, .variable => true,
        else => false,
    };
}

/// The clauses of a statement, as far as completion needs them.
const Clause = enum { none, select, from, where, group, order, having, on, set, values, into, other };

/// Where a table reference is being read, while the scope is built.
const RefState = enum {
    /// No table name is expected.
    none,
    /// A table name is expected, after FROM, JOIN, or a comma in the FROM list.
    table,
    /// A table name was read, and an alias or a dot may follow.
    name,
    /// A dot followed a database name, and a table name is expected.
    dot,
    /// A table name was read after its database, and an alias may follow.
    qualified,
    /// AS followed a table name, and an alias is expected.
    alias_after_as,
    /// A `)` closed a parenthesis that opened a table reference, as in `FROM (SELECT ...) x`, and
    /// an alias may follow it.
    derived,
    /// AS followed a derived table, or the row of an INSERT, and an alias is expected.
    derived_as,
};

/// How many tokens before the cursor the context keeps, enough for the longest rule.
const max_prev = 8;

/// How many parentheses that open a table reference can be open at once.
const max_opened = 8;

/// The state of the scan. It is reset at each statement boundary.
const State = struct {
    /// The first token of the statement.
    first: ?Sig = null,
    /// The last tokens before the word at the cursor, oldest first.
    prev: [max_prev]Sig = undefined,
    prev_len: usize = 0,
    clause: Clause = .none,
    scope: Scope = .{},
    /// True while the tokens name a list of tables, as in `FROM a, b`.
    from_list: bool = false,
    ref: RefState = .none,
    /// The scope index of the table being read.
    ref_index: ?usize = null,
    /// The word at the cursor, which is being completed.
    partial: ?Sig = null,
    /// How many parentheses are open.
    depth: usize = 0,
    /// The depths of the open parentheses that opened a table reference, innermost last.
    opened: [max_opened]usize = undefined,
    opened_len: usize = 0,
    /// Set when a table may be missing from the scope, as with a table function or very deep
    /// nesting. `unknownQualifier` then reports nothing.
    unsure: bool = false,

    fn reset(self: *State) void {
        self.* = .{};
    }

    fn prevItems(self: *const State) []const Sig {
        return self.prev[0..self.prev_len];
    }

    fn pushPrev(self: *State, sig: Sig) void {
        if (self.prev_len == max_prev) {
            std.mem.copyForwards(Sig, self.prev[0 .. max_prev - 1], self.prev[1..max_prev]);
            self.prev_len -= 1;
        }
        self.prev[self.prev_len] = sig;
        self.prev_len += 1;
    }

    /// A token that ends before the cursor. It counts for the rules and for the scope.
    fn addBefore(self: *State, sig: Sig) void {
        self.noteFirst(sig);
        self.pushPrev(sig);
        self.updateClause(sig);
        self.feedRef(sig);
    }

    /// A token at or after the cursor. It can only add a table to the scope.
    fn addAfter(self: *State, sig: Sig) void {
        self.feedRef(sig);
    }

    fn noteFirst(self: *State, sig: Sig) void {
        if (self.first == null) self.first = sig;
    }

    fn firstIs(self: *const State, word: []const u8) bool {
        const first = self.first orelse return false;
        return first.is(word);
    }

    fn updateClause(self: *State, sig: Sig) void {
        if (!isWordKind(sig.kind)) return;
        if (sig.is("SELECT")) {
            self.clause = .select;
        } else if (sig.is("FROM") or sig.is("JOIN") or sig.is("STRAIGHT_JOIN")) {
            self.clause = .from;
        } else if (sig.is("UPDATE")) {
            self.clause = if (self.firstIs("UPDATE")) .from else .set;
        } else if (sig.is("INTO")) {
            self.clause = .into;
        } else if (sig.is("WHERE")) {
            self.clause = .where;
        } else if (sig.is("GROUP")) {
            self.clause = .group;
        } else if (sig.is("ORDER")) {
            self.clause = .order;
        } else if (sig.is("HAVING")) {
            self.clause = .having;
        } else if (sig.is("ON")) {
            self.clause = .on;
        } else if (sig.is("SET")) {
            self.clause = .set;
        } else if (sig.is("VALUES") or sig.is("VALUE")) {
            self.clause = .values;
        } else if (sig.is("LIMIT") or sig.is("DELETE") or sig.is("INSERT") or sig.is("REPLACE") or sig.is("USING")) {
            self.clause = .other;
        }
    }

    /// Reads a table reference, so the scope holds the tables the statement names.
    fn feedRef(self: *State, sig: Sig) void {
        self.noteFirst(sig);
        if (sig.isPunct(",")) {
            if (self.from_list) self.ref = .table;
            return;
        }
        if (sig.isPunct("(")) return self.openParen();
        if (sig.isPunct(")")) return self.closeParen();
        if (isWordKind(sig.kind)) {
            const starts_tables = sig.is("FROM") or sig.is("JOIN") or sig.is("STRAIGHT_JOIN") or
                (sig.is("UPDATE") and self.firstIs("UPDATE")) or (sig.is("USING") and self.firstIs("DELETE"));
            if (starts_tables) {
                self.startTables(true);
                return;
            }
            if (sig.is("INTO") and (self.firstIs("INSERT") or self.firstIs("REPLACE"))) {
                self.startTables(false);
                return;
            }
            if (self.ref == .table and sig.is("LATERAL")) return;
            const row_alias = sig.is("AS") and self.ref == .none and self.clause == .values and
                (self.firstIs("INSERT") or self.firstIs("REPLACE"));
            if (row_alias) {
                // The row alias of `VALUES (...) AS new`, which is a name for the row.
                self.ref = .derived_as;
                return;
            }
            if (sig.is("WHERE") or sig.is("GROUP") or sig.is("ORDER") or sig.is("HAVING") or sig.is("LIMIT") or
                sig.is("SET") or sig.is("VALUES") or sig.is("VALUE") or sig.is("SELECT") or sig.is("ON") or
                sig.is("USING") or sig.is("WITH"))
            {
                self.from_list = false;
                self.ref = .none;
                return;
            }
        }
        switch (self.ref) {
            .none => {},
            .table => {
                if (isNameKind(sig.kind)) {
                    self.ref_index = self.scope.add(.{ .table = sig.text });
                    self.ref = .name;
                } else {
                    // A table function, such as JSON_TABLE, adds a table that is not recorded.
                    if (sig.kind == .function) self.unsure = true;
                    self.ref = .none;
                }
            },
            .name => {
                if (sig.kind == .dot) {
                    self.ref = .dot;
                } else if (sig.is("AS")) {
                    self.ref = .alias_after_as;
                } else {
                    self.readAlias(sig);
                }
            },
            .dot => {
                if (isNameKind(sig.kind)) {
                    if (self.ref_index) |index| {
                        self.scope.items[index].schema = self.scope.items[index].table;
                        self.scope.items[index].table = sig.text;
                    }
                    self.ref = .qualified;
                } else {
                    self.ref = .none;
                }
            },
            .qualified => {
                if (sig.is("AS")) {
                    self.ref = .alias_after_as;
                } else {
                    self.readAlias(sig);
                }
            },
            .alias_after_as => self.readAlias(sig),
            .derived => {
                if (sig.is("AS")) {
                    self.ref = .derived_as;
                } else {
                    self.readDerivedAlias(sig);
                }
            },
            .derived_as => self.readDerivedAlias(sig),
        }
    }

    fn startTables(self: *State, from: bool) void {
        self.ref = .table;
        self.from_list = from;
    }

    /// An open parenthesis. Where a table is expected it may open a derived table, so its depth
    /// is kept until the matching close. Elsewhere it ends the table reference.
    fn openParen(self: *State) void {
        self.depth += 1;
        if (self.ref != .table) {
            self.ref = .none;
            return;
        }
        if (self.opened_len == max_opened) {
            self.unsure = true;
            return;
        }
        self.opened[self.opened_len] = self.depth;
        self.opened_len += 1;
    }

    /// A close parenthesis. When it closes one that opened a table reference, an alias may follow.
    fn closeParen(self: *State) void {
        if (self.opened_len > 0 and self.opened[self.opened_len - 1] == self.depth) {
            self.opened_len -= 1;
            self.ref = .derived;
        } else {
            self.ref = .none;
        }
        self.depth -|= 1;
    }

    /// Adds the derived table named by `sig`, when it is a name, and ends the reference.
    fn readDerivedAlias(self: *State, sig: Sig) void {
        if (isNameKind(sig.kind)) {
            _ = self.scope.add(.{ .table = sig.text, .derived = true });
        }
        self.ref = .none;
    }

    /// Sets the alias of the table being read, when `sig` can be one, and ends the reference.
    fn readAlias(self: *State, sig: Sig) void {
        if (isNameKind(sig.kind)) {
            if (self.ref_index) |index| self.scope.items[index].alias = sig.text;
        }
        self.ref = .none;
    }

    /// The expectation at the end of the text before the cursor.
    fn classify(self: *const State) Expect {
        const prev = self.prevItems();
        const n = prev.len;
        if (n == 0) return .{ .keyword = .statement };
        const last = prev[n - 1];

        if (last.kind == .dot) return self.afterDot(prev);
        if (last.kind == .punctuation) {
            if (last.isPunct(",")) return self.afterComma();
            if (last.isPunct("(")) return self.afterParen();
            return .{ .keyword = .any };
        }
        if (last.kind == .operator) {
            const star = std.mem.eql(u8, last.text, "*");
            if (star and n >= 2 and (prev[n - 2].is("SELECT") or prev[n - 2].isPunct(","))) {
                return .{ .keyword = .any };
            }
            return self.columns();
        }
        if (!isWordKind(last.kind)) return .{ .keyword = .any };
        return self.afterWord(prev);
    }

    fn columns(self: *const State) Expect {
        return .{ .column = self.scope };
    }

    /// The rules for the word before the cursor.
    fn afterWord(self: *const State, prev: []const Sig) Expect {
        const n = prev.len;
        const last = prev[n - 1];
        if (last.is("FROM")) {
            if (self.firstIs("SHOW")) {
                // SHOW COLUMNS FROM names a table; SHOW TABLES FROM names a database.
                if (n >= 2 and (prev[n - 2].is("COLUMNS") or prev[n - 2].is("INDEX") or prev[n - 2].is("INDEXES") or prev[n - 2].is("KEYS"))) {
                    return .{ .table = null };
                }
                return .database;
            }
            return .{ .table = null };
        }
        if (last.is("JOIN") or last.is("TABLE") or last.is("TRUNCATE")) return .{ .table = null };
        if (last.is("INTO")) return if (self.firstIs("SELECT")) .variable else .{ .table = null };
        if (last.is("UPDATE")) return if (self.firstIs("UPDATE")) .{ .table = null } else self.columns();
        if (last.is("DESCRIBE") or last.is("DESC") or last.is("EXPLAIN")) {
            return if (n == 1) .{ .table = null } else .{ .keyword = .any };
        }
        if (last.is("USE")) return .database;
        if (last.is("DATABASE") or last.is("SCHEMA")) {
            if (self.firstIs("CREATE") or self.firstIs("DROP") or self.firstIs("ALTER")) return .database;
            return .{ .keyword = .any };
        }
        if (last.is("CALL")) return .routine;
        if (last.is("PROCEDURE") or last.is("FUNCTION")) {
            if (self.firstIs("DROP") or self.firstIs("ALTER") or self.firstIs("SHOW")) return .routine;
            return .{ .keyword = .any };
        }
        if (last.is("BY") and n >= 2 and (prev[n - 2].is("GROUP") or prev[n - 2].is("ORDER"))) return self.columns();
        if (last.is("SET")) return if (self.firstIs("SET")) .variable else self.columns();
        if (last.is("SELECT") or last.is("WHERE") or last.is("ON") or last.is("AND") or last.is("OR") or
            last.is("XOR") or last.is("NOT") or last.is("HAVING") or last.is("DISTINCT") or last.is("WHEN") or
            last.is("THEN") or last.is("ELSE") or last.is("CASE"))
        {
            return self.columns();
        }
        return .{ .keyword = .any };
    }

    /// After a comma: the next table of a FROM list, or the next column of a list of columns.
    fn afterComma(self: *const State) Expect {
        return switch (self.clause) {
            .from => .{ .table = null },
            .into => if (self.firstIs("INSERT") or self.firstIs("REPLACE")) self.columns() else .{ .keyword = .any },
            .select, .group, .order, .set, .having => self.columns(),
            .values => .none,
            else => .{ .keyword = .any },
        };
    }

    /// After an open parenthesis: a column list, an expression, or a subquery.
    fn afterParen(self: *const State) Expect {
        return switch (self.clause) {
            .values => .none,
            .from => .{ .keyword = .statement },
            else => self.columns(),
        };
    }

    /// After a dot: a column of the table before it, or a table of the database before it.
    fn afterDot(self: *const State, prev: []const Sig) Expect {
        const n = prev.len;
        if (n < 2 or !isNameKind(prev[n - 2].kind)) return .none;
        const name = prev[n - 2];
        var qualifier_start = n - 2;
        var schema: ?Sig = null;
        if (n >= 4 and prev[n - 3].kind == .dot and isNameKind(prev[n - 4].kind)) {
            schema = prev[n - 4];
            qualifier_start = n - 4;
        }
        if (self.tableExpectedAfter(prev[0..qualifier_start])) {
            if (schema != null) return .none;
            return .{ .table = name.text };
        }
        if (schema) |db| return .{ .column_of = .{ .schema = db.text, .table = name.text } };
        return .{ .column_of = self.resolve(name.text) };
    }

    /// True when the tokens `before` are followed by a table name.
    fn tableExpectedAfter(self: *const State, before: []const Sig) bool {
        const n = before.len;
        if (n == 0) return false;
        const last = before[n - 1];
        if (last.is("FROM") or last.is("JOIN") or last.is("TABLE") or last.is("TRUNCATE")) return true;
        if (last.is("INTO")) return !self.firstIs("SELECT");
        if (last.is("UPDATE")) return self.firstIs("UPDATE");
        if (last.is("DESCRIBE") or last.is("DESC") or last.is("EXPLAIN")) return n == 1;
        if (last.isPunct(",")) return self.clause == .from;
        return false;
    }

    /// The table that `name` stands for in the statement: a table alias or a table name
    /// that is in scope, or else a table of the current database.
    fn resolve(self: *const State, name: []const u8) TableRef {
        const refs = self.scope.slice();
        for (refs) |ref| {
            if (ref.alias) |alias| {
                if (std.ascii.eqlIgnoreCase(alias, name)) return ref;
            }
        }
        for (refs) |ref| {
            if (ref.alias == null and std.ascii.eqlIgnoreCase(ref.table, name)) return ref;
        }
        return .{ .table = name };
    }
};

/// A column qualifier that names no table or alias of its statement. See `unknownQualifier`.
pub const UnknownQualifier = struct {
    /// Byte offsets of the qualifier in `text`, without quotes, end exclusive.
    start: usize,
    end: usize,
    /// The qualifier as written, without quotes. A slice of `text`.
    name: []const u8,
    /// A table of the statement with no alias whose name starts with `name`, ignoring case, as a
    /// hint: `did you mean "foo f"?`. Null when there is none.
    suggestion: ?TableRef,
    /// The tables that the statement names, in order.
    scope: Scope,
};

/// The column qualifier of the statement that holds `cursor` that names no table or alias of that
/// statement and is nearest the cursor, or null. A tie goes to the earlier one. `cursor` is a byte
/// offset into `text`. `options` are the session's lexer settings. The result refers to `text`.
///
/// A qualifier is a name followed by a dot and a column, as `f` in `f.id`, and it can be left
/// open, as in `f.|`. The whole statement is read, so a table after the cursor counts. Only the
/// statements that name tables are checked: queries and writes of rows. Nothing is reported when
/// the scope is empty or full, when the statement has a table function or is nested too deeply,
/// when the name is a table in a table position (`db.t` after FROM), a schema or function
/// qualifier (`db.t.col`, `db.f(1)`), `NEW` or `OLD`, a CTE name, or when the cursor is on the name,
/// since it may still be typed.
pub fn unknownQualifier(text: []const u8, cursor: usize, options: LexOptions) ?UnknownQualifier {
    const bounds = statementBounds(text, cursor, options);

    // The first pass reads the scope of the whole statement, since a table may be named after
    // the qualifier that uses it.
    var scope_state: State = .{};
    var lexer = statementLexer(text, options, bounds.start);
    while (nextSig(&lexer, bounds.end)) |tok| {
        scope_state.addBefore(Sig.of(tok.kind, text[tok.start..tok.end]));
    }
    const first = scope_state.first orelse return null;
    if (!namesTables(first)) return null;
    const scope = scope_state.scope;
    if (scope_state.unsure or scope.len == 0 or scope.len == max_scope) return null;
    const with_statement = first.is("WITH");

    // The second pass finds the qualifiers, with the table positions known as the scope is read.
    // The unknown one nearest the cursor is the one being typed, so it is the one reported.
    var best: ?UnknownQualifier = null;
    var best_gap: usize = 0;
    var state: State = .{};
    lexer = statementLexer(text, options, bounds.start);
    while (nextSig(&lexer, bounds.end)) |tok| {
        const sig = Sig.of(tok.kind, text[tok.start..tok.end]);
        const in_expression = state.ref != .table and !afterDot(state.prevItems());
        if (isNameKind(tok.kind) and in_expression and isQualifier(text, lexer, bounds.end)) {
            const inner: usize = if (tok.kind == .quoted_identifier) 1 else 0;
            const start = tok.start + inner;
            const end = start + sig.text.len;
            const typing = start <= cursor and cursor <= end;
            const known = isKnownQualifier(&scope, sig.text) or
                (with_statement and definesCte(text, options, bounds, sig.text));
            if (!typing and !known) {
                const gap = gapBetween(cursor, start, end);
                if (best == null or gap < best_gap) {
                    best = .{
                        .start = start,
                        .end = end,
                        .name = sig.text,
                        .suggestion = suggestionFor(&scope, sig.text),
                        .scope = scope,
                    };
                    best_gap = gap;
                }
            }
        }
        state.addBefore(sig);
    }
    return best;
}

/// The number of bytes from `cursor` to the span `start..end`, or 0 when the cursor is in it.
fn gapBetween(cursor: usize, start: usize, end: usize) usize {
    if (cursor < start) return start - cursor;
    if (cursor > end) return cursor - end;
    return 0;
}

/// Writes the message for `uq`, without a newline. With a suggestion it reads
/// `unknown table or alias "f"; did you mean "foo f"?`. Otherwise it lists the tables that the
/// statement names: `unknown table or alias "f" (tables here: foo, bar b)`.
pub fn formatUnknownQualifier(writer: *std.Io.Writer, uq: UnknownQualifier) std.Io.Writer.Error!void {
    try writer.print("unknown table or alias \"{s}\"", .{uq.name});
    if (uq.suggestion) |ref| {
        try writer.writeAll("; did you mean \"");
        try writeQualified(writer, ref);
        try writer.print(" {s}\"?", .{uq.name});
        return;
    }
    try writer.writeAll(" (tables here: ");
    for (uq.scope.slice(), 0..) |ref, i| {
        if (i > 0) try writer.writeAll(", ");
        try writeQualified(writer, ref);
        if (ref.alias) |alias| try writer.print(" {s}", .{alias});
    }
    try writer.writeAll(")");
}

/// Writes `schema.table`, or just `table` when the reference has no schema.
fn writeQualified(writer: *std.Io.Writer, ref: TableRef) std.Io.Writer.Error!void {
    if (ref.schema) |name| try writer.print("{s}.", .{name});
    try writer.writeAll(ref.table);
}

/// The bytes of one statement: from just after the delimiter or client command before it, to the
/// one at or after the cursor, or to the end of the text.
const Bounds = struct {
    start: usize,
    end: usize,
};

/// The statement that holds `cursor`, found the way `expectAt` splits statements.
fn statementBounds(text: []const u8, cursor: usize, options: LexOptions) Bounds {
    var bounds: Bounds = .{ .start = 0, .end = text.len };
    var lexer = Lexer.init(text, options);
    while (lexer.next()) |tok| {
        if (tok.kind != .delimiter and tok.kind != .client_command) continue;
        if (tok.start >= cursor) {
            bounds.end = tok.start;
            break;
        }
        bounds.start = tok.end;
    }
    return bounds;
}

/// A lexer that reads the statement that starts at `start`.
fn statementLexer(text: []const u8, options: LexOptions, start: usize) Lexer {
    var lexer = Lexer.init(text, options);
    lexer.pos = start;
    return lexer;
}

/// The next token that the context reads before `end`: whitespace, comments, hints and version
/// comment markers are skipped. Null at `end`.
fn nextSig(lexer: *Lexer, end: usize) ?Token {
    while (lexer.next()) |tok| {
        if (tok.start >= end) return null;
        switch (tok.kind) {
            .whitespace, .comment, .optimizer_hint, .version_comment_start, .version_comment_end => continue,
            else => return tok,
        }
    }
    return null;
}

/// True for the statements whose table names the scope reads: queries and the writes of rows.
/// Other statements, such as `CREATE INDEX ... ON db.t`, are not checked.
fn namesTables(first: Sig) bool {
    return first.is("SELECT") or first.is("WITH") or first.is("UPDATE") or first.is("DELETE") or
        first.is("INSERT") or first.is("REPLACE");
}

/// True when the name that `lexer` has just read is followed by a dot and a column, and that column
/// is not followed by another dot or a `(`, which would make the name a schema or a function.
fn isQualifier(text: []const u8, lexer: Lexer, end: usize) bool {
    var look = lexer;
    const dot = nextSig(&look, end) orelse return false;
    if (dot.kind != .dot) return false;
    const column = nextSig(&look, end) orelse return true;
    if (!isNameKind(column.kind) and column.kind != .function) return true;
    const after = nextSig(&look, end) orelse return true;
    if (after.kind == .dot) return false;
    return !(after.kind == .punctuation and text[after.start] == '(');
}

/// True when the tokens before a name end with a dot, so the name is the last part of a qualified name.
fn afterDot(prev: []const Sig) bool {
    return prev.len > 0 and prev[prev.len - 1].kind == .dot;
}

/// True when `name` is a table or an alias of the scope, or `NEW` or `OLD`, which a trigger body
/// always has. A table name counts even when the table has an alias, which MySQL does not allow,
/// so that a name that the user may have meant is not reported.
fn isKnownQualifier(scope: *const Scope, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "new") or std.ascii.eqlIgnoreCase(name, "old")) return true;
    for (scope.slice()) |ref| {
        if (std.ascii.eqlIgnoreCase(ref.table, name)) return true;
        if (ref.alias) |alias| {
            if (std.ascii.eqlIgnoreCase(alias, name)) return true;
        }
    }
    return false;
}

/// True when the statement `bounds` defines a common table expression called `name`: the name is
/// followed by `AS` or by a column list.
fn definesCte(text: []const u8, options: LexOptions, bounds: Bounds, name: []const u8) bool {
    var lexer = statementLexer(text, options, bounds.start);
    while (nextSig(&lexer, bounds.end)) |tok| {
        if (!isNameKind(tok.kind)) continue;
        if (!std.ascii.eqlIgnoreCase(Sig.of(tok.kind, text[tok.start..tok.end]).text, name)) continue;
        var look = lexer;
        const after = nextSig(&look, bounds.end) orelse continue;
        if (after.kind == .punctuation and text[after.start] == '(') return true;
        if (Sig.of(after.kind, text[after.start..after.end]).is("AS")) return true;
    }
    return false;
}

/// The table of the scope that a qualifier `name` may have been meant for: one with no alias whose
/// name starts with `name`, ignoring case. Derived tables are not tables, so they are skipped.
fn suggestionFor(scope: *const Scope, name: []const u8) ?TableRef {
    if (name.len == 0) return null;
    for (scope.slice()) |ref| {
        if (ref.alias != null or ref.derived or ref.table.len < name.len) continue;
        if (std.ascii.eqlIgnoreCase(ref.table[0..name.len], name)) return ref;
    }
    return null;
}

/// Writes `expect` as a short line that the tests compare, such as `column[people,app.orders]`.
fn describe(allocator: std.mem.Allocator, expect: Expect) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (expect) {
        .keyword => |set| try out.appendSlice(allocator, if (set == .statement) "keyword statement" else "keyword any"),
        .database => try out.appendSlice(allocator, "database"),
        .table => |schema| {
            try out.appendSlice(allocator, "table");
            if (schema) |name| {
                try out.append(allocator, ':');
                try out.appendSlice(allocator, name);
            }
        },
        .column => |scope| {
            try out.appendSlice(allocator, "column[");
            for (scope.slice(), 0..) |ref, i| {
                if (i > 0) try out.append(allocator, ',');
                try appendQualified(allocator, &out, ref);
            }
            try out.append(allocator, ']');
        },
        .column_of => |ref| {
            try out.appendSlice(allocator, "column_of:");
            try appendQualified(allocator, &out, ref);
        },
        .routine => try out.appendSlice(allocator, "routine"),
        .variable => try out.appendSlice(allocator, "variable"),
        .client_command => try out.appendSlice(allocator, "client_command"),
        .none => try out.appendSlice(allocator, "none"),
    }
    return out.toOwnedSlice(allocator);
}

/// Appends `schema.table`, or just `table` when the reference has no schema.
fn appendQualified(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ref: TableRef) std.mem.Allocator.Error!void {
    if (ref.schema) |name| {
        try out.appendSlice(allocator, name);
        try out.append(allocator, '.');
    }
    try out.appendSlice(allocator, ref.table);
}

/// Runs `expectAt` on `case`, where `|` marks the cursor, and compares the description.
fn expectCase(case: []const u8, want: []const u8) !void {
    const allocator = std.testing.allocator;
    const cursor = std.mem.indexOfScalar(u8, case, '|') orelse return error.MissingCursor;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, case[0..cursor]);
    try text.appendSlice(allocator, case[cursor + 1 ..]);

    const got = try describe(allocator, expectAt(text.items, cursor, .{}));
    defer allocator.free(got);
    std.testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("case: {s}\n", .{case});
        return err;
    };
}

test "statement start expects a statement keyword" {
    try expectCase("|", "keyword statement");
    try expectCase("sel|", "keyword statement");
    try expectCase("select 1; |", "keyword statement");
    try expectCase("SHOW DATABASES; sel|", "keyword statement");
}

test "after FROM, JOIN, UPDATE, INTO, TABLE, TRUNCATE and table commands a table is expected" {
    try expectCase("SELECT * FROM |", "table");
    try expectCase("SELECT * FROM people p JOIN |", "table");
    try expectCase("SELECT * FROM people, |", "table");
    try expectCase("UPDATE |", "table");
    try expectCase("INSERT INTO |", "table");
    try expectCase("DELETE FROM |", "table");
    try expectCase("DROP TABLE |", "table");
    try expectCase("TRUNCATE |", "table");
    try expectCase("ALTER TABLE |", "table");
    try expectCase("DESCRIBE |", "table");
    try expectCase("DESC |", "table");
    try expectCase("SHOW COLUMNS FROM |", "table");
    try expectCase("SHOW INDEX FROM |", "table");
}

test "after USE, SHOW TABLES FROM and CREATE or DROP DATABASE a database is expected" {
    try expectCase("USE |", "database");
    try expectCase("SHOW TABLES FROM |", "database");
    try expectCase("CREATE DATABASE |", "database");
    try expectCase("DROP SCHEMA |", "database");
}

test "after SELECT, WHERE, ON, AND, SET and a comma in a select list a column is expected" {
    try expectCase("SELECT |", "column[]");
    try expectCase("SELECT a, |", "column[]");
    try expectCase("SELECT a FROM t WHERE x = 1 AND |", "column[t]");
    try expectCase("SELECT * FROM a JOIN b ON |", "column[a,b]");
    try expectCase("UPDATE people SET |", "column[people]");
    try expectCase("SELECT * FROM t ORDER BY a, |", "column[t]");
    try expectCase("SELECT * FROM t GROUP BY |", "column[t]");
    try expectCase("SELECT * FROM t WHERE a IN (|", "column[t]");
    try expectCase("SELECT COUNT(|", "column[]");
    try expectCase("SELECT DISTINCT |", "column[]");
    try expectCase("SELECT a FROM t WHERE x = |", "column[t]");
    try expectCase("SELECT a |", "keyword any");
}

test "a column list of INSERT names the table it inserts into" {
    try expectCase("INSERT INTO people (|", "column[people]");
    try expectCase("INSERT INTO people (a, |) VALUES (1, 2)", "column[people]");
    try expectCase("INSERT INTO people VALUES (|", "none");
}

test "after a dot the table or alias before it is resolved" {
    try expectCase("SELECT p.| FROM people p", "column_of:people");
    try expectCase("SELECT x.| FROM people AS x JOIN orders y", "column_of:people");
    try expectCase("SELECT y.| FROM people AS x JOIN orders y", "column_of:orders");
    try expectCase("SELECT app.people.| FROM app.people", "column_of:app.people");
    try expectCase("SELECT people.| FROM app.people", "column_of:app.people");
    try expectCase("SELECT t.| ", "column_of:t");
    try expectCase("SELECT * FROM people p WHERE p.n|", "column_of:people");
    try expectCase("SELECT * FROM t1 a, t2 b WHERE a.|", "column_of:t1");
}

test "after a database and a dot in a table position the tables of that database are expected" {
    try expectCase("SELECT * FROM app.|", "table:app");
    try expectCase("SELECT * FROM app.ord|", "table:app");
}

test "a variable after @@ or @" {
    try expectCase("SELECT @@|", "variable");
    try expectCase("SELECT @@sql_m|", "variable");
    try expectCase("SELECT @x|", "variable");
}

test "a client command after a backslash" {
    try expectCase("\\|", "client_command");
    try expectCase("SELECT 1\\G |", "keyword statement");
}

test "inside a string or comment nothing is expected" {
    try expectCase("SELECT 'abc|", "none");
    try expectCase("SELECT 1 -- a|", "none");
    try expectCase("SELECT /* x| */ 1", "none");
    try expectCase("SELECT 'a' |", "keyword any");
}

test "the scope is the statement at the cursor, and ends at the delimiter" {
    try expectCase("CREATE TABLE x (a INT); SELECT a FROM x WHERE a = 1 AND |", "column[x]");
    try expectCase("SELECT 1; SELECT |", "column[]");
    try expectCase("SELECT * FROM a; SELECT x.| FROM b x", "column_of:b");
}

test "a multi-line statement counts its earlier lines" {
    try expectCase("SELECT a\nFROM t\n  WHERE |", "column[t]");
}

test "routines follow CALL, and DROP, ALTER or SHOW of a procedure or function" {
    try expectCase("CALL |", "routine");
    try expectCase("DROP PROCEDURE |", "routine");
    try expectCase("SHOW CREATE FUNCTION |", "routine");
}

test "a subquery after an opening parenthesis in FROM expects a statement" {
    try expectCase("SELECT * FROM (|", "keyword statement");
}

test "a quoted table name is read without its backticks" {
    try expectCase("SELECT * FROM `my tab` x WHERE |", "column[my tab]");
}

test "a name that needs quoting is quoted, and reserved words always are" {
    try std.testing.expect(!needsQuoting("people"));
    try std.testing.expect(!needsQuoting("account"));
    try std.testing.expect(!needsQuoting("_x$1"));
    try std.testing.expect(needsQuoting(""));
    try std.testing.expect(needsQuoting("my table"));
    try std.testing.expect(needsQuoting("a-b"));
    try std.testing.expect(needsQuoting("123"));
    try std.testing.expect(needsQuoting("select"));
}

test "a derived table names its alias, which then counts as a table" {
    try expectCase("SELECT * FROM (SELECT a FROM t) d WHERE |", "column[t,d]");
    try expectCase("SELECT d.| FROM (SELECT a FROM t) AS d", "column_of:d");
}

/// Runs `unknownQualifier` on `case`, where `|` marks the cursor, and compares the message that
/// `formatUnknownQualifier` writes, or `none` when there is no unknown qualifier.
fn expectUnknownCase(case: []const u8, want: []const u8) !void {
    const allocator = std.testing.allocator;
    const cursor = std.mem.indexOfScalar(u8, case, '|') orelse return error.MissingCursor;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, case[0..cursor]);
    try text.appendSlice(allocator, case[cursor + 1 ..]);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (unknownQualifier(text.items, cursor, .{})) |uq| {
        try formatUnknownQualifier(&out.writer, uq);
    } else {
        try out.writer.writeAll("none");
    }
    std.testing.expectEqualStrings(want, out.written()) catch |err| {
        std.debug.print("case: {s}\n", .{case});
        return err;
    };
}

test "a qualifier that names no table or alias is reported, with a hint for a table" {
    try expectUnknownCase(
        "select f.id from foo join bar b on f.id = b.id limit |",
        "unknown table or alias \"f\"; did you mean \"foo f\"?",
    );
    try expectUnknownCase(
        "select f.id from foo join bar b on x.| limit 1;",
        "unknown table or alias \"x\" (tables here: foo, bar b)",
    );
    try expectUnknownCase(
        "select f.id from foo join bar b on f.|",
        "unknown table or alias \"f\"; did you mean \"foo f\"?",
    );
    try expectUnknownCase("SELECT z.a FROM t1 a, t2 b|", "unknown table or alias \"z\" (tables here: t1 a, t2 b)");
    try expectUnknownCase("SELECT `q`.a FROM t|", "unknown table or alias \"q\" (tables here: t)");
    try expectUnknownCase("SELECT z.a FROM `my tab` x|", "unknown table or alias \"z\" (tables here: my tab x)");
    try expectUnknownCase("SELECT z.a FROM app.people|", "unknown table or alias \"z\" (tables here: app.people)");
    try expectUnknownCase("SELECT p.id FROM app.people|", "unknown table or alias \"p\"; did you mean \"app.people p\"?");
    try expectUnknownCase("select x| from foo where f.id = 1", "unknown table or alias \"f\"; did you mean \"foo f\"?");
    try expectUnknownCase(
        "SELECT * FROM t1 a, t2 b WHERE a.id = 1 AND 2 = t3.id|",
        "unknown table or alias \"t3\" (tables here: t1 a, t2 b)",
    );
    try expectUnknownCase("UPDATE t1 SET t1.a = 1 WHERE t2.a = 1|", "unknown table or alias \"t2\" (tables here: t1)");
}

test "the offsets of a qualifier cover its name, without quotes" {
    const plain = "select f.id from foo";
    const plain_uq = unknownQualifier(plain, plain.len, .{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 7), plain_uq.start);
    try std.testing.expectEqual(@as(usize, 8), plain_uq.end);
    try std.testing.expectEqualStrings("f", plain[plain_uq.start..plain_uq.end]);

    const quoted = "SELECT `q`.a FROM t";
    const quoted_uq = unknownQualifier(quoted, quoted.len, .{}) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 8), quoted_uq.start);
    try std.testing.expectEqual(@as(usize, 9), quoted_uq.end);
    try std.testing.expectEqualStrings("q", quoted[quoted_uq.start..quoted_uq.end]);
}

test "with ANSI_QUOTES a double-quoted qualifier is read without its quotes" {
    const text = "SELECT \"q\".a FROM t";
    const uq = unknownQualifier(text, text.len, .{ .ansi_quotes = true }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("q", uq.name);
}

test "of several unknown qualifiers, the one nearest the cursor is reported" {
    try expectUnknownCase("SELECT a.x FROM t WHERE b.y = 1 AND |", "unknown table or alias \"b\" (tables here: t)");
    try expectUnknownCase("SELECT a.x, b.y FROM t|", "unknown table or alias \"b\" (tables here: t)");
}

test "only the statement that holds the cursor is checked" {
    try expectUnknownCase("select z.a from t; select a from t|", "none");
    try expectUnknownCase("select z.a from t|; select a from t", "unknown table or alias \"z\" (tables here: t)");
}

test "nothing is reported when no table is named, so a qualifier cannot be checked" {
    try expectUnknownCase("select f.|", "none");
    try expectUnknownCase("SELECT 1|", "none");
}

test "text in strings, comments and variables is not a qualifier" {
    try expectUnknownCase("SELECT 1 FROM t -- f.|", "none");
    try expectUnknownCase("SELECT 'f.x' FROM t|", "none");
    try expectUnknownCase("SELECT @v.x FROM t|", "none");
}

test "a qualifier that names a table or alias is known" {
    try expectUnknownCase("select f.id from foo f where f.|", "none");
    try expectUnknownCase("select foo.id from foo f where foo.|", "none");
    try expectUnknownCase("SELECT t.* FROM t|", "none");
    try expectUnknownCase("SELECT x.a FROM (SELECT a FROM t) x|", "none");
    try expectUnknownCase("SELECT d.a FROM foo JOIN (SELECT 1 AS a) AS d ON d.a = foo.a|", "none");
}

test "a derived table's alias is known, and other names after it are not" {
    try expectUnknownCase(
        "SELECT * FROM (SELECT a FROM t) x WHERE x.a = 1 AND y.b = 2|",
        "unknown table or alias \"y\" (tables here: t, x)",
    );
}

test "a qualifier that is a schema or function is not a column qualifier" {
    try expectUnknownCase("select app.foo.id from app.foo|", "none");
    try expectUnknownCase("select app.f(1) from foo|", "none");
    try expectUnknownCase("SELECT db.func(1) FROM t|", "none");
}

test "a table in a table position is not a qualifier" {
    try expectUnknownCase("SELECT * FROM t1 a, db.t2 b WHERE a.id = 1|", "none");
    try expectUnknownCase("SELECT * FROM t1 a STRAIGHT_JOIN db.t2 b ON a.id = b.id|", "none");
    try expectUnknownCase("DELETE FROM t1 USING db.t2 WHERE t1.a = t2.a|", "none");
    try expectUnknownCase("INSERT INTO db.t (a) VALUES (1)|", "none");
    try expectUnknownCase("SELECT * FROM t1 JOIN LATERAL (SELECT 1) AS lat WHERE lat.a = t1.a|", "none");
}

test "a name that is being typed is not reported" {
    try expectUnknownCase("SELECT f|.id FROM foo", "none");
}

test "NEW and OLD are always known, and a CTE name is known" {
    try expectUnknownCase("UPDATE t SET a = NEW.b WHERE t.id = 1|", "none");
    try expectUnknownCase("WITH c AS (SELECT 1 AS a) SELECT c.a FROM t|", "none");
    try expectUnknownCase("WITH c AS (SELECT 1 AS a) SELECT d.a FROM t|", "unknown table or alias \"d\" (tables here: t)");
}

test "a row alias of INSERT is known" {
    try expectUnknownCase("INSERT INTO t (a) VALUES (1) AS new ON DUPLICATE KEY UPDATE a = new.a|", "none");
}

test "a table function makes the scope unsure, so nothing is reported" {
    try expectUnknownCase(
        "SELECT jt.a FROM foo, JSON_TABLE('[1]', '$[*]' COLUMNS (a INT PATH '$')) AS jt WHERE jt.a = 1 AND f.b = 2|",
        "none",
    );
}

test "a statement that is not a query or a write of rows is not checked" {
    try expectUnknownCase("CREATE INDEX i ON db.t (f.a)|", "none");
    try expectUnknownCase("CALL db.proc(f.x)|", "none");
}

test "a subquery's tables are in the scope of the whole statement" {
    try expectUnknownCase("SELECT f.a FROM t WHERE a IN (SELECT b FROM u)|", "unknown table or alias \"f\" (tables here: t, u)");
}

/// Builds `SELECT z.a FROM t0, t1, ...` with `count` tables, for the scope limit.
fn manyTables(comptime count: usize) []const u8 {
    comptime {
        var text: []const u8 = "SELECT z.a FROM t0";
        for (1..count) |i| text = text ++ std.fmt.comptimePrint(", t{d}", .{i});
        return text;
    }
}

test "a full scope gives no diagnosis, since a name may be missing from it" {
    const almost = comptime manyTables(max_scope - 1);
    try std.testing.expect(unknownQualifier(almost, almost.len, .{}) != null);
    const full = comptime manyTables(max_scope);
    try std.testing.expect(unknownQualifier(full, full.len, .{}) == null);
}
