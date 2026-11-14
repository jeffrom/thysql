//! A tokenizer for MySQL 8.4 SQL, following the "Language Structure" chapter of the manual.
//! It allocates nothing: a `Lexer` is a position in the text, and `next` returns the token
//! there. Tokens cover every byte of the text, whitespace included, so a caller can style
//! or check any part of it. The lexer does not check syntax.
//!
//! Input may end in the middle of a string, quoted identifier or comment, as a line being
//! typed does. Such a token runs to the end of the text and has `unterminated` set.

const std = @import("std");
const keywords = @import("keywords.zig");

/// The settings that change how text is read. They follow the session's sql_mode.
pub const Options = struct {
    /// Double quotes delimit identifiers, as with ANSI_QUOTES, rather than strings.
    ansi_quotes: bool = false,
    /// Backslash is an ordinary byte in strings, as with NO_BACKSLASH_ESCAPES.
    no_backslash_escapes: bool = false,
    /// The statement delimiter, such as `;` or `$$`. Empty means there is none.
    delimiter: []const u8 = ";",
};

/// What a token is.
pub const Kind = enum {
    whitespace,
    /// A `#`, `-- ` or `/* */` comment.
    comment,
    /// An optimizer hint, `/*+ ... */`.
    optimizer_hint,
    /// The `/*!` or `/*!80000` that opens a version comment. The SQL inside is lexed as usual.
    version_comment_start,
    /// The `*/` that closes a version comment.
    version_comment_end,
    /// A quoted string, including a charset introducer such as `_utf8mb4'x'` and the `N`,
    /// `X` and `B` prefixes of `N'x'`, `X'0f'` and `B'01'`.
    string,
    /// A word that is neither a keyword nor a function call.
    identifier,
    /// A backtick identifier, or a double-quoted one with ANSI_QUOTES.
    quoted_identifier,
    /// A keyword that cannot be used as an unquoted identifier.
    reserved_keyword,
    /// A keyword that can also be an identifier, such as `ACCOUNT`.
    keyword,
    /// A built-in function name followed directly by `(`.
    function,
    /// An integer, decimal or float, or a hex (`0x0f`) or bit (`0b01`) number.
    number,
    /// A user variable such as `@x`, `@'x'` or `` @`x` ``, or a system variable such as `@@sql_mode`.
    variable,
    /// A `?` placeholder.
    placeholder,
    operator,
    /// The `.` between the parts of a qualified name.
    dot,
    /// A parenthesis, comma or `;` that is not the delimiter.
    punctuation,
    /// The statement delimiter.
    delimiter,
    /// A client command. At the start of a statement this is `DELIMITER x`, `SOURCE file`, or a
    /// backslash command, which runs to the end of its line. Otherwise it is a backslash
    /// command such as `\G`, which is two bytes long.
    client_command,
    /// A byte that no other rule takes, such as a stray control character.
    unknown,
};

/// One token: its kind, and the bytes `text[start..end]` that it covers.
pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    /// True for a string, quoted identifier, or comment that runs to the end of the text
    /// without its closing mark. Its `end` is the end of the text.
    unterminated: bool = false,
};

/// Reads tokens from `text`, one after another. Create it with `init`, then call `next`
/// until it returns null.
pub const Lexer = struct {
    text: []const u8,
    options: Options,
    /// Where the next token starts.
    pos: usize = 0,
    /// Inside a version comment, which ends at its `*/`. The delimiter is not recognized there.
    in_version_comment: bool = false,
    /// True where a statement can begin: at the start of the text, or after a delimiter or a
    /// client command. `DELIMITER` and `SOURCE` are client commands only there.
    statement_start: bool = true,

    /// Starts reading `text` from its first byte, as the start of a statement.
    pub fn init(text: []const u8, options: Options) Lexer {
        return .{ .text = text, .options = options };
    }

    /// The next token, or null at the end of the text. Every token covers at least one byte.
    pub fn next(self: *Lexer) ?Token {
        if (self.pos >= self.text.len) return null;
        const tok = self.scan();
        std.debug.assert(tok.end > tok.start);
        self.pos = tok.end;
        switch (tok.kind) {
            .whitespace, .comment, .optimizer_hint, .version_comment_start, .version_comment_end => {},
            .delimiter, .client_command => self.statement_start = true,
            else => self.statement_start = false,
        }
        return tok;
    }

    fn scan(self: *Lexer) Token {
        const text = self.text;
        const start = self.pos;
        const byte = text[start];

        if (isSpace(byte)) {
            return token(.whitespace, start, skipSpaces(text, start), false);
        }
        if (self.in_version_comment and std.mem.startsWith(u8, text[start..], "*/")) {
            self.in_version_comment = false;
            return token(.version_comment_end, start, start + 2, false);
        }
        if (self.delimiterAt(start)) {
            return token(.delimiter, start, start + self.options.delimiter.len, false);
        }

        switch (byte) {
            '#' => return self.lineComment(start),
            '-' => if (startsDashComment(text, start)) return self.lineComment(start),
            '/' => if (start + 1 < text.len and text[start + 1] == '*') return self.blockComment(start),
            '\'' => return self.quoted(.string, start, '\'', self.backslashInStrings()),
            '"' => if (self.options.ansi_quotes) {
                return self.quoted(.quoted_identifier, start, '"', false);
            } else {
                return self.quoted(.string, start, '"', self.backslashInStrings());
            },
            '`' => return self.quoted(.quoted_identifier, start, '`', false),
            '@' => return self.variable(start),
            '?' => return token(.placeholder, start, start + 1, false),
            '0'...'9' => return self.numberOrWord(start),
            '.' => if (start + 1 < text.len and std.ascii.isDigit(text[start + 1])) {
                return self.numberOrWord(start);
            } else {
                return token(.dot, start, start + 1, false);
            },
            '\\' => return self.backslashCommand(start),
            '(', ')', ',', ';' => return token(.punctuation, start, start + 1, false),
            else => {},
        }
        if (isWordStart(byte)) return self.word(start);
        if (operatorEnd(text, start)) |end| return token(.operator, start, end, false);
        return token(.unknown, start, start + 1, false);
    }

    fn backslashInStrings(self: *const Lexer) bool {
        return !self.options.no_backslash_escapes;
    }

    /// True when the delimiter starts at `pos`. Inside a version comment it does not count.
    fn delimiterAt(self: *const Lexer, pos: usize) bool {
        const delimiter = self.options.delimiter;
        return delimiter.len > 0 and !self.in_version_comment and std.mem.startsWith(u8, self.text[pos..], delimiter);
    }

    /// A `#` or `--` comment, which runs to the end of its line.
    fn lineComment(self: *const Lexer, start: usize) Token {
        const end = std.mem.indexOfScalarPos(u8, self.text, start, '\n') orelse self.text.len;
        return token(.comment, start, end, false);
    }

    /// A `/* */` comment, an optimizer hint `/*+`, or the opening of a version comment `/*!`.
    fn blockComment(self: *Lexer, start: usize) Token {
        const text = self.text;
        const marker: u8 = if (start + 2 < text.len) text[start + 2] else 0;
        if (marker == '!') {
            // The version number after `/*!` is five digits at most, as in `/*!80000`.
            var end = start + 3;
            while (end < text.len and end < start + 8 and std.ascii.isDigit(text[end])) end += 1;
            self.in_version_comment = true;
            return token(.version_comment_start, start, end, false);
        }
        const kind: Kind = if (marker == '+') .optimizer_hint else .comment;
        if (std.mem.indexOfPos(u8, text, start + 2, "*/")) |close| {
            return token(kind, start, close + 2, false);
        }
        return token(kind, start, text.len, true);
    }

    /// A quoted string or identifier, from the quote at `start`.
    fn quoted(self: *const Lexer, kind: Kind, start: usize, quote: u8, backslash: bool) Token {
        const end = self.quotedEnd(start, quote, backslash);
        return token(kind, start, end.end, end.unterminated);
    }

    const QuotedEnd = struct { end: usize, unterminated: bool };

    /// Finds the end of the quoted run whose opening quote is at `quote_pos`. A doubled quote
    /// stays inside the run, and so does a backslash-escaped byte when `backslash` is set.
    fn quotedEnd(self: *const Lexer, quote_pos: usize, quote: u8, backslash: bool) QuotedEnd {
        const text = self.text;
        var i = quote_pos + 1;
        while (i < text.len) {
            const byte = text[i];
            if (backslash and byte == '\\') {
                i += 2;
            } else if (byte == quote) {
                if (i + 1 < text.len and text[i + 1] == quote) {
                    i += 2;
                } else {
                    return .{ .end = i + 1, .unterminated = false };
                }
            } else {
                i += 1;
            }
        }
        return .{ .end = text.len, .unterminated = true };
    }

    /// A user variable: `@name`, `@'name'`, `` @`name` `` or the `@@name` of a system variable.
    /// A lone `@` is unknown.
    fn variable(self: *const Lexer, start: usize) Token {
        const text = self.text;
        var i = start + 1;
        if (i < text.len and text[i] == '@') i += 1;
        if (i < text.len and (text[i] == '\'' or text[i] == '"' or text[i] == '`')) {
            const quote = text[i];
            const end = self.quotedEnd(i, quote, quote != '`' and self.backslashInStrings());
            return token(.variable, start, end.end, end.unterminated);
        }
        if (i < text.len and isWordByte(text[i]) and !self.delimiterAt(i)) {
            return token(.variable, start, self.wordEnd(i), false);
        }
        return token(.unknown, start, i, false);
    }

    /// A backslash client command. A `\` at the start of a statement takes the rest of its line,
    /// as `\u db` does. Elsewhere it is the two bytes `\G` or `\c`.
    fn backslashCommand(self: *const Lexer, start: usize) Token {
        const text = self.text;
        if (start + 1 >= text.len or text[start + 1] == '\n') {
            return token(.client_command, start, start + 1, false);
        }
        if (self.statement_start) {
            const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
            return token(.client_command, start, end, false);
        }
        return token(.client_command, start, start + 2, false);
    }

    /// A number, or a word that starts with digits, such as `1abc`, which is an identifier.
    fn numberOrWord(self: *const Lexer, start: usize) Token {
        const text = self.text;
        const end = numberEnd(text, start);
        if (text[start] != '.' and end < text.len and isWordByte(text[end]) and !self.delimiterAt(end)) {
            return self.word(start);
        }
        return token(.number, start, end, false);
    }

    /// A word (identifier, keyword or function name), or a string with a charset introducer or
    /// a `N`, `X` or `B` prefix. It may also be a client command such as `DELIMITER` at the start
    /// of a statement.
    fn word(self: *const Lexer, start: usize) Token {
        const text = self.text;
        const end = self.wordEnd(start);
        const name = text[start..end];

        if (end < text.len and text[end] == '\'' and isStringPrefix(name)) {
            const string_end = self.quotedEnd(end, '\'', self.backslashInStrings());
            return token(.string, start, string_end.end, string_end.unterminated);
        }
        if (self.statement_start and end < text.len and isSpace(text[end]) and
            (std.ascii.eqlIgnoreCase(name, "delimiter") or std.ascii.eqlIgnoreCase(name, "source")))
        {
            const line_end = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse text.len;
            return token(.client_command, start, line_end, false);
        }
        if (end < text.len and text[end] == '(' and keywords.isFunction(name)) {
            return token(.function, start, end, false);
        }
        if (keywords.find(name)) |keyword| {
            return token(if (keyword.reserved) .reserved_keyword else .keyword, start, end, false);
        }
        return token(.identifier, start, end, false);
    }

    /// The end of the word that starts at `start`. A word stops before the delimiter.
    fn wordEnd(self: *const Lexer, start: usize) usize {
        var end = start;
        while (end < self.text.len and isWordByte(self.text[end]) and !self.delimiterAt(end)) end += 1;
        return @max(end, start + 1);
    }
};

fn token(kind: Kind, start: usize, end: usize, unterminated: bool) Token {
    return .{ .kind = kind, .start = start, .end = end, .unterminated = unterminated };
}

fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn skipSpaces(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and isSpace(text[end])) end += 1;
    return end;
}

/// Bytes that can be in an unquoted identifier: letters, digits, `_`, `$`, and any byte from
/// 0x80 up, which carries UTF-8.
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

/// Bytes that can start an identifier. A digit can only start a number.
fn isWordStart(byte: u8) bool {
    return isWordByte(byte) and !std.ascii.isDigit(byte);
}

/// `--` starts a comment only when a space, a control byte or the end of the text follows it.
fn startsDashComment(text: []const u8, start: usize) bool {
    if (!std.mem.startsWith(u8, text[start..], "--")) return false;
    if (start + 2 == text.len) return true;
    const next = text[start + 2];
    return next <= ' ' or next == 0x7f;
}

/// True when `name` is a charset introducer such as `_utf8mb4`, or one of the `N`, `X` and `B`
/// prefixes of a string.
fn isStringPrefix(name: []const u8) bool {
    if (name.len == 1) {
        return switch (name[0]) {
            'N', 'n', 'X', 'x', 'B', 'b' => true,
            else => false,
        };
    }
    if (name.len < 2 or name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return false;
    }
    return true;
}

/// The end of the number that starts at `start`. A number is hex (`0x`) or bit (`0b`) digits,
/// or decimal digits with an optional fraction and exponent. `.5` is a number too.
fn numberEnd(text: []const u8, start: usize) usize {
    if (text[start] == '0' and start + 2 < text.len) {
        const prefix = text[start + 1];
        if (prefix == 'x' or prefix == 'X') {
            var end = start + 2;
            while (end < text.len and std.ascii.isHex(text[end])) end += 1;
            if (end > start + 2) return end;
        } else if (prefix == 'b' or prefix == 'B') {
            var end = start + 2;
            while (end < text.len and (text[end] == '0' or text[end] == '1')) end += 1;
            if (end > start + 2) return end;
        }
    }

    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end < text.len and text[end] == '.') {
        end += 1;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    }
    if (end < text.len and (text[end] == 'e' or text[end] == 'E')) {
        var exponent = end + 1;
        if (exponent < text.len and (text[exponent] == '+' or text[exponent] == '-')) exponent += 1;
        if (exponent < text.len and std.ascii.isDigit(text[exponent])) {
            while (exponent < text.len and std.ascii.isDigit(text[exponent])) exponent += 1;
            end = exponent;
        }
    }
    return end;
}

/// Operators, longest first, so that `<=>` is not read as `<=` and `>`.
const operators = [_][]const u8{
    "<=>", "->>", "->", ":=", "<<", ">>", "&&", "||", "!=", "<>", "<=", ">=",
    "!",   "~",   "&",  "|",  "^",  "+",  "-",  "*",  "/",  "%",  "=",  "<",
    ">",
};

/// The end of the operator at `start`, or null when none starts there.
fn operatorEnd(text: []const u8, start: usize) ?usize {
    for (operators) |operator| {
        if (std.mem.startsWith(u8, text[start..], operator)) return start + operator.len;
    }
    return null;
}

test "lexer covers every byte of the text in order" {
    const text = "select `a`, 'b' /* c */ from t; -- d\n# e\n";
    var lexer = Lexer.init(text, .{});
    var covered: usize = 0;
    while (lexer.next()) |tok| {
        try std.testing.expectEqual(covered, tok.start);
        covered = tok.end;
    }
    try std.testing.expectEqual(text.len, covered);
}
