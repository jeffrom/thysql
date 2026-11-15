//! Client commands: the words and backslash forms that mysql.cc runs instead of
//! sending SQL. `parse` is pure, so it is tested without a server. Batch and
//! REPL input both run what it returns, from src/root.zig.

const std = @import("std");

pub const Kind = enum {
    quit,
    help,
    status,
    use,
    print,
    pager,
    nopager,
    tee,
    notee,
    warnings,
    nowarnings,
    connect,
    connection,
    prompt,
    rehash,
    yank,
};

pub const Command = struct {
    kind: Kind,
    /// The text after the command, trimmed. Empty when there is none.
    arg: []const u8 = "",
    /// The text after the command with only the leading whitespace removed. Trailing
    /// spaces stay, because a prompt may end with one.
    rest: []const u8 = "",
};

const Named = struct { name: []const u8, kind: Kind, takes_arg: bool };
const Short = struct { char: u8, kind: Kind, takes_arg: bool };

/// Word forms, matched case-insensitively. A word with an argument must allow one.
const named = [_]Named{
    .{ .name = "?", .kind = .help, .takes_arg = true },
    .{ .name = "connect", .kind = .connect, .takes_arg = true },
    .{ .name = "connection", .kind = .connection, .takes_arg = true },
    .{ .name = "exit", .kind = .quit, .takes_arg = false },
    .{ .name = "help", .kind = .help, .takes_arg = true },
    .{ .name = "nopager", .kind = .nopager, .takes_arg = false },
    .{ .name = "notee", .kind = .notee, .takes_arg = false },
    .{ .name = "nowarning", .kind = .nowarnings, .takes_arg = false },
    .{ .name = "pager", .kind = .pager, .takes_arg = true },
    .{ .name = "print", .kind = .print, .takes_arg = false },
    .{ .name = "prompt", .kind = .prompt, .takes_arg = true },
    .{ .name = "quit", .kind = .quit, .takes_arg = false },
    .{ .name = "rehash", .kind = .rehash, .takes_arg = false },
    .{ .name = "status", .kind = .status, .takes_arg = false },
    .{ .name = "tee", .kind = .tee, .takes_arg = true },
    .{ .name = "use", .kind = .use, .takes_arg = true },
    .{ .name = "warnings", .kind = .warnings, .takes_arg = false },
    .{ .name = "yank", .kind = .yank, .takes_arg = true },
};

/// Backslash forms such as \s. The character must be followed by whitespace or the end.
const short = [_]Short{
    .{ .char = 'q', .kind = .quit, .takes_arg = false },
    .{ .char = 'h', .kind = .help, .takes_arg = true },
    .{ .char = '?', .kind = .help, .takes_arg = true },
    .{ .char = 's', .kind = .status, .takes_arg = false },
    .{ .char = 'u', .kind = .use, .takes_arg = true },
    .{ .char = 'p', .kind = .print, .takes_arg = false },
    .{ .char = 'P', .kind = .pager, .takes_arg = true },
    .{ .char = 'n', .kind = .nopager, .takes_arg = false },
    .{ .char = 'T', .kind = .tee, .takes_arg = true },
    .{ .char = 't', .kind = .notee, .takes_arg = false },
    .{ .char = 'W', .kind = .warnings, .takes_arg = false },
    .{ .char = 'w', .kind = .nowarnings, .takes_arg = false },
    .{ .char = 'r', .kind = .connect, .takes_arg = true },
    .{ .char = 'C', .kind = .connection, .takes_arg = true },
    .{ .char = 'R', .kind = .prompt, .takes_arg = true },
    .{ .char = '#', .kind = .rehash, .takes_arg = false },
    .{ .char = 'y', .kind = .yank, .takes_arg = true },
};

const whitespace = " \t\r\n";

/// True when a backslash followed by `byte` starts a client command.
pub fn isShortChar(byte: u8) bool {
    for (short) |entry| {
        if (entry.char == byte) return true;
    }
    return false;
}

/// Returns the client command that `input` holds, or null when it is SQL. A
/// trailing `;` is ignored, as it is when a statement ends with the delimiter.
pub fn parse(input: []const u8) ?Command {
    // `body` keeps trailing spaces for `rest`. Only the line ending is removed from it.
    const body = std.mem.trimEnd(u8, std.mem.trimStart(u8, input, whitespace), "\r\n");
    var text = std.mem.trim(u8, body, whitespace);
    if (text.len > 0 and text[text.len - 1] == ';') {
        text = std.mem.trimEnd(u8, text[0 .. text.len - 1], whitespace);
    }
    if (text.len == 0) {
        return null;
    }
    if (text[0] == '\\') {
        return parseShort(text, body);
    }
    return parseNamed(text, body);
}

fn parseNamed(text: []const u8, body: []const u8) ?Command {
    const split = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    const word = text[0..split];
    const arg = std.mem.trim(u8, text[split..], " \t");
    for (named) |entry| {
        if (!std.ascii.eqlIgnoreCase(word, entry.name)) {
            continue;
        }
        if (arg.len > 0 and !entry.takes_arg) {
            return null;
        }
        return .{ .kind = entry.kind, .arg = arg, .rest = std.mem.trimStart(u8, body[split..], " \t") };
    }
    return null;
}

fn parseShort(text: []const u8, body: []const u8) ?Command {
    if (text.len < 2) {
        return null;
    }
    if (text.len > 2 and !std.ascii.isWhitespace(text[2])) {
        return null;
    }
    for (short) |entry| {
        if (entry.char != text[1]) {
            continue;
        }
        const arg = std.mem.trim(u8, text[2..], whitespace);
        if (arg.len > 0 and !entry.takes_arg) {
            return null;
        }
        return .{ .kind = entry.kind, .arg = arg, .rest = std.mem.trimStart(u8, body[2..], " \t") };
    }
    return null;
}

/// Where the connection name starts when `line` is `\C name` or `connection name`, with any case for
/// the word, and the cursor is in the name. Null otherwise. The name is the text from there to `cursor`,
/// and it has no whitespace in it. Only a line that starts with the command counts.
pub fn connectionNameStart(line: []const u8, cursor: usize) ?usize {
    const first = std.mem.indexOfNone(u8, line, whitespace) orelse return null;
    if (cursor <= first) return null;
    const head = line[first..cursor];

    const command_len: usize = if (std.mem.startsWith(u8, head, "\\C"))
        2
    else if (head.len > 10 and std.ascii.eqlIgnoreCase(head[0..10], "connection"))
        10
    else
        return null;
    if (command_len >= head.len or !std.ascii.isWhitespace(head[command_len])) return null;

    var name = command_len;
    while (name < head.len and std.ascii.isWhitespace(head[name])) name += 1;
    for (head[name..]) |byte| {
        if (std.ascii.isWhitespace(byte)) return null;
    }
    return first + name;
}

/// Lines for `help`, in mysql.cc's order. Only commands that thysql runs are listed.
pub const help_items = [_]struct { name: []const u8, char: u8, doc: []const u8 }{
    .{ .name = "?", .char = '?', .doc = "Synonym for `help'." },
    .{ .name = "clear", .char = 'c', .doc = "Clear the current input statement." },
    .{ .name = "connect", .char = 'r', .doc = "Reconnect to the server. Optional arguments are db and host." },
    .{ .name = "connection", .char = 'C', .doc = "Switch to a saved connection. With no name, list them." },
    .{ .name = "delimiter", .char = 'd', .doc = "Set statement delimiter." },
    .{ .name = "edit", .char = 'e', .doc = "Edit command with $EDITOR." },
    .{ .name = "exit", .char = 'q', .doc = "Exit thysql. Same as quit." },
    .{ .name = "help", .char = 'h', .doc = "Display this help." },
    .{ .name = "nopager", .char = 'n', .doc = "Disable pager, print to stdout." },
    .{ .name = "notee", .char = 't', .doc = "Don't write into outfile." },
    .{ .name = "nowarning", .char = 'w', .doc = "Don't show warnings after every statement." },
    .{ .name = "pager", .char = 'P', .doc = "Set PAGER [to_pager]. Print the query results via PAGER." },
    .{ .name = "print", .char = 'p', .doc = "Print current command." },
    .{ .name = "prompt", .char = 'R', .doc = "Change your mysql prompt." },
    .{ .name = "quit", .char = 'q', .doc = "Quit thysql." },
    .{ .name = "rehash", .char = '#', .doc = "Rebuild completion hash." },
    .{ .name = "source", .char = '.', .doc = "Execute an SQL script file. Takes a file name as an argument." },
    .{ .name = "status", .char = 's', .doc = "Get status information from the server." },
    .{ .name = "tee", .char = 'T', .doc = "Set outfile [to_outfile]. Append everything into given outfile." },
    .{ .name = "use", .char = 'u', .doc = "Use another database. Takes database name as argument." },
    .{ .name = "warnings", .char = 'W', .doc = "Show warnings after every statement." },
    .{ .name = "yank", .char = 'y', .doc = "Copy the last result set to the clipboard. Optional format argument." },
};

/// Prints the list for `help`, in the format of mysql.cc's com_help.
pub fn renderHelp(out: *std.Io.Writer) !void {
    try out.print("List of all client commands:\n", .{});
    for (help_items) |item| {
        try out.print("{s: <11}(\\{c}) {s}\n", .{ item.name, item.char, item.doc });
    }
}

test "named commands match case-insensitively and take an argument only where allowed" {
    try std.testing.expectEqual(Kind.quit, parse("quit").?.kind);
    try std.testing.expectEqual(Kind.quit, parse("EXIT;").?.kind);
    try std.testing.expectEqual(Kind.status, parse("  status  ").?.kind);
    try std.testing.expectEqual(@as(?Command, null), parse("quit now"));
    try std.testing.expectEqual(@as(?Command, null), parse("warnings extra"));
    try std.testing.expectEqual(@as(?Command, null), parse("select 1"));
    try std.testing.expectEqual(@as(?Command, null), parse("statuses"));

    const use = parse("use `my db`;").?;
    try std.testing.expectEqual(Kind.use, use.kind);
    try std.testing.expectEqualStrings("`my db`", use.arg);

    const pager = parse("pager less -R").?;
    try std.testing.expectEqual(Kind.pager, pager.kind);
    try std.testing.expectEqualStrings("less -R", pager.arg);
}

test "backslash commands need whitespace before an argument" {
    try std.testing.expectEqual(Kind.status, parse("\\s").?.kind);
    try std.testing.expectEqual(Kind.warnings, parse("\\W").?.kind);
    try std.testing.expectEqual(Kind.nowarnings, parse("\\w;").?.kind);

    const pager = parse("\\P   less ").?;
    try std.testing.expectEqual(Kind.pager, pager.kind);
    try std.testing.expectEqualStrings("less", pager.arg);

    const bare_pager = parse("\\P").?;
    try std.testing.expectEqualStrings("", bare_pager.arg);

    try std.testing.expectEqual(@as(?Command, null), parse("\\Pless"));
    try std.testing.expectEqual(@as(?Command, null), parse("\\W extra"));
    try std.testing.expectEqual(@as(?Command, null), parse("\\G"));
    try std.testing.expectEqual(@as(?Command, null), parse("\\"));
}

test "only backslash forms with a command letter are client commands" {
    try std.testing.expect(isShortChar('P'));
    try std.testing.expect(isShortChar('?'));
    try std.testing.expect(isShortChar('#'));
    try std.testing.expect(!isShortChar('G'));
    try std.testing.expect(!isShortChar('c'));
}

test "connect, prompt, and rehash parse in both forms" {
    const connect = parse("connect app db.example").?;
    try std.testing.expectEqual(Kind.connect, connect.kind);
    try std.testing.expectEqualStrings("app db.example", connect.arg);

    try std.testing.expectEqual(Kind.connect, parse("\\r").?.kind);
    try std.testing.expectEqualStrings("app", parse("\\r   app").?.arg);
    try std.testing.expectEqual(Kind.rehash, parse("rehash").?.kind);
    try std.testing.expectEqual(Kind.rehash, parse("\\#").?.kind);
    try std.testing.expectEqual(@as(?Command, null), parse("\\#now"));
    try std.testing.expectEqual(@as(?Command, null), parse("rehash now"));
}

test "prompt keeps the raw text, including trailing spaces" {
    const named_prompt = parse("prompt \\u@\\h> ").?;
    try std.testing.expectEqual(Kind.prompt, named_prompt.kind);
    try std.testing.expectEqualStrings("\\u@\\h> ", named_prompt.rest);
    try std.testing.expectEqualStrings("\\u@\\h>", named_prompt.arg);

    const short_prompt = parse("\\R   \\d>  ").?;
    try std.testing.expectEqualStrings("\\d>  ", short_prompt.rest);

    const bare = parse("\\R").?;
    try std.testing.expectEqualStrings("", bare.rest);
}

test "connection takes a name in both forms, and \\C is a short command" {
    try std.testing.expect(isShortChar('C'));
    const short_form = parse("\\C maria").?;
    try std.testing.expectEqual(Kind.connection, short_form.kind);
    try std.testing.expectEqualStrings("maria", short_form.arg);

    const word_form = parse("CONNECTION main/ro;").?;
    try std.testing.expectEqual(Kind.connection, word_form.kind);
    try std.testing.expectEqualStrings("main/ro", word_form.arg);

    const listing = parse("\\C").?;
    try std.testing.expectEqual(Kind.connection, listing.kind);
    try std.testing.expectEqualStrings("", listing.arg);
    try std.testing.expectEqual(Kind.connect, parse("connect app").?.kind);
}

test "the connection name is where completion of \\C starts" {
    try std.testing.expectEqual(@as(?usize, 3), connectionNameStart("\\C ma", 5));
    try std.testing.expectEqual(@as(?usize, 3), connectionNameStart("\\C ", 3));
    try std.testing.expectEqual(@as(?usize, 13), connectionNameStart("  connection main/", 18));
    try std.testing.expectEqual(@as(?usize, null), connectionNameStart("\\C", 2));
    try std.testing.expectEqual(@as(?usize, null), connectionNameStart("\\Cx ma", 6));
    try std.testing.expectEqual(@as(?usize, null), connectionNameStart("select \\C", 9));
    try std.testing.expectEqual(@as(?usize, null), connectionNameStart("\\C ma x", 6));
    try std.testing.expectEqual(@as(?usize, null), connectionNameStart("connections ma", 14));
}

test "help lists each command with its backslash form" {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try renderHelp(&out);
    const text = out.buffered();

    try std.testing.expect(std.mem.startsWith(u8, text, "List of all client commands:\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "help       (\\h) Display this help.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "connection (\\C) Switch to a saved connection. With no name, list them.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tee        (\\T) Set outfile [to_outfile].") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "warnings   (\\W) Show warnings after every statement.\n") != null);
}

test "yank takes an optional format in both forms" {
    try std.testing.expect(isShortChar('y'));
    const short_form = parse("\\y csv;").?;
    try std.testing.expectEqual(Kind.yank, short_form.kind);
    try std.testing.expectEqualStrings("csv", short_form.arg);

    const bare = parse("\\y").?;
    try std.testing.expectEqual(Kind.yank, bare.kind);
    try std.testing.expectEqualStrings("", bare.arg);

    const word_form = parse("YANK json").?;
    try std.testing.expectEqual(Kind.yank, word_form.kind);
    try std.testing.expectEqualStrings("json", word_form.arg);
    try std.testing.expectEqual(@as(?Command, null), parse("\\yank"));
}
