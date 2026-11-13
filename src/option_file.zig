//! MySQL option files, read as mysql.cc does through MariaDB's load_defaults.
//! Unless --no-defaults is given, thysql reads /etc/my.cnf, /etc/mysql/my.cnf,
//! --defaults-extra-file, and then $HOME/.my.cnf. Later files override earlier
//! ones, and command-line flags override all of them (see options.zig).
//!
//! Only the groups in `groups` are read. Unknown option names are not an error;
//! options.zig ignores them. `Setting`s keep the names as written in the file.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The groups mysql.cc and MariaDB clients read, in the order they are listed.
pub const groups = [_][]const u8{ "client", "mysql", "mariadb-client", "client-mariadb", "mariadb" };

const system_files = [_][]const u8{ "/etc/my.cnf", "/etc/mysql/my.cnf" };
const max_include_depth = 10;
const max_file_size = 16 * 1024 * 1024;
const whitespace = " \t\r\n\x0b\x0c";

pub const Error = error{ OptionFileFailed, OutOfMemory };

pub const LeadingError = error{DefaultsOptionMisplaced};

pub const Setting = struct {
    /// The name as written in the file, without the leading "--".
    name: []const u8,
    /// Null for a bare name such as `skip-column-names`. An empty value is "".
    value: ?[]const u8,
};

/// The defaults options that must come first on the command line.
pub const Leading = struct {
    no_defaults: bool = false,
    defaults_file: ?[]const u8 = null,
    extra_file: ?[]const u8 = null,
    print_defaults: bool = false,
    /// Index of the first argument after the defaults options.
    next: usize = 1,
};

/// The result of `load`. Settings point into the arena, so keep this alive while they are used.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    settings: []const Setting,
    print_defaults: bool,
    next: usize,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

/// Reads the leading defaults options and the option files they select. Errors
/// are printed to `stderr` before `error.OptionFileFailed` is returned.
pub fn load(
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) Error!Loaded {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const leading = parseLeading(args) catch {
        stderr.print("--no-defaults, --defaults-file, --defaults-extra-file, and --print-defaults must come first on the command line, each at most once.\n", .{}) catch {};
        return error.OptionFileFailed;
    };

    // An empty HOME means no home directory, so ~/.my.cnf is not read from the working directory.
    const home: ?[]const u8 = if (env.get("HOME")) |value| (if (value.len > 0) value else null) else null;
    var loader = Loader{
        .allocator = allocator,
        .io = io,
        .home = home,
        .stderr = stderr,
    };
    if (!leading.no_defaults) {
        try loader.readDefaults(leading);
    }

    return .{
        .arena = arena,
        .settings = try loader.settings.toOwnedSlice(allocator),
        .print_defaults = leading.print_defaults,
        .next = leading.next,
    };
}

/// Reads `--no-defaults`, or `--defaults-file=` and `--defaults-extra-file=`, then
/// `--print-defaults`, from the start of args. As in MariaDB, these must come first.
pub fn parseLeading(args: []const []const u8) LeadingError!Leading {
    var leading: Leading = .{};
    if (args.len > 1 and std.mem.eql(u8, args[1], "--no-defaults")) {
        leading.no_defaults = true;
        leading.next = 2;
        return leading;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (valueAfter(args[i], "--defaults-file=")) |path| {
            if (leading.defaults_file != null) return error.DefaultsOptionMisplaced;
            leading.defaults_file = path;
        } else if (valueAfter(args[i], "--defaults-extra-file=")) |path| {
            if (leading.extra_file != null) return error.DefaultsOptionMisplaced;
            leading.extra_file = path;
        } else {
            break;
        }
    }

    if (i < args.len and std.mem.eql(u8, args[i], "--print-defaults")) {
        leading.print_defaults = true;
        i += 1;
    }
    leading.next = i;
    return leading;
}

/// True for the options that only parseLeading accepts. Seeing one elsewhere is an error.
pub fn isLeadingOnly(name: []const u8) bool {
    const names = [_][]const u8{ "no-defaults", "defaults-file", "defaults-extra-file", "print-defaults" };
    for (names) |candidate| {
        if (sameName(name, candidate)) return true;
    }
    return false;
}

/// Option names match with "-" and "_" treated alike, as MariaDB does.
pub fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (normalizeNameByte(x) != normalizeNameByte(y)) return false;
    }
    return true;
}

fn normalizeNameByte(byte: u8) u8 {
    return if (byte == '_') '-' else byte;
}

/// Drops a leading "loose-" prefix. A loose option is ignored when it is unknown,
/// and options.zig ignores all unknown file options, so only the prefix matters.
pub fn withoutLoose(name: []const u8) []const u8 {
    if (name.len >= 6 and sameName(name[0..6], "loose-")) {
        return name[6..];
    }
    return name;
}

/// Prints the settings and the remaining arguments as MariaDB's --print-defaults
/// does. Password values are masked, so they do not reach the terminal.
pub fn renderPrintDefaults(
    out: *std.Io.Writer,
    program: []const u8,
    settings: []const Setting,
    rest: []const []const u8,
) !void {
    try out.print("{s} would have been started with the following arguments:\n", .{program});
    for (settings) |setting| {
        try out.print("--{s}", .{setting.name});
        if (setting.value) |value| {
            const shown = if (isPasswordName(setting.name)) "***" else value;
            try out.print("={s}", .{shown});
        }
        try out.writeByte(' ');
    }
    for (rest) |arg| {
        try out.print("{s} ", .{arg});
    }
    try out.writeByte('\n');
}

fn isPasswordName(name: []const u8) bool {
    return sameName(withoutLoose(name), "password");
}

fn valueAfter(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) {
        return arg[prefix.len..];
    }
    return null;
}

/// Turns a value from a file into its final text. As in mysql.cc, the value is
/// trimmed, one pair of matching quotes is removed, and these escapes are expanded:
/// \n \t \r \b \s \" \' \\. Any other backslash is kept, and so is a trailing one.
pub fn unescapeValue(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var text = std.mem.trim(u8, raw, whitespace);
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'') and text[text.len - 1] == text[0]) {
        text = text[1 .. text.len - 1];
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 == text.len) {
            try out.append(allocator, text[i]);
            i += 1;
            continue;
        }
        const escaped = text[i + 1];
        i += 2;
        const mapped: ?u8 = switch (escaped) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 0x08,
            's' => ' ',
            '"', '\'', '\\' => escaped,
            else => null,
        };
        if (mapped) |byte| {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '\\');
            try out.append(allocator, escaped);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// The index where a `#` comment starts, or text.len. A `#` inside quotes is not a comment,
/// and a backslash escapes the next quote inside quotes, as in mysql.cc.
pub fn commentStart(text: []const u8) usize {
    var quote: u8 = 0;
    var escape = false;
    for (text, 0..) |byte, index| {
        if ((byte == '\'' or byte == '"') and !escape) {
            if (quote == 0) {
                quote = byte;
            } else if (quote == byte) {
                quote = 0;
            }
        }
        if (quote == 0 and byte == '#') {
            return index;
        }
        escape = quote != 0 and byte == '\\' and !escape;
    }
    return text.len;
}

fn isWantedGroup(name: []const u8) bool {
    for (groups) |group| {
        if (std.ascii.eqlIgnoreCase(group, name)) return true;
    }
    return false;
}

const Section = enum { none, wanted, other };

const Directive = enum { include, includedir };

const Loader = struct {
    allocator: Allocator,
    io: std.Io,
    home: ?[]const u8,
    stderr: *std.Io.Writer,
    settings: std.ArrayList(Setting) = .empty,

    fn readDefaults(self: *Loader, leading: Leading) Error!void {
        if (leading.defaults_file) |path| {
            const found = try self.readFile(try self.expandHome(path), 0);
            if (!found) {
                return self.fail("Could not open required defaults file: {s}", .{path});
            }
            return;
        }

        for (system_files) |path| {
            _ = try self.readFile(path, 0);
        }
        if (leading.extra_file) |path| {
            const found = try self.readFile(try self.expandHome(path), 0);
            if (!found) {
                return self.fail("Could not open required defaults file: {s}", .{path});
            }
        }
        if (self.home) |home| {
            const path = try std.fs.path.join(self.allocator, &.{ home, ".my.cnf" });
            _ = try self.readFile(path, 0);
        }
    }

    /// Reads and parses one file. Returns false when it is missing or unreadable, which is not an error.
    fn readFile(self: *Loader, path: []const u8, depth: usize) Error!bool {
        const text = std.Io.Dir.readFileAlloc(.cwd(), self.io, path, self.allocator, .limited(max_file_size)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return false;
        };
        try self.parseText(text, path, depth);
        return true;
    }

    fn parseText(self: *Loader, text: []const u8, path: []const u8, depth: usize) Error!void {
        var section: Section = .none;
        var line_number: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            line_number += 1;
            const line = std.mem.trim(u8, raw_line, whitespace);
            if (line.len == 0 or line[0] == '#' or line[0] == ';') {
                continue;
            }
            if (line[0] == '!') {
                try self.directive(line[1..], path, line_number, depth);
                continue;
            }
            if (line[0] == '[') {
                const close = std.mem.indexOfScalar(u8, line, ']') orelse {
                    return self.fail("error: Wrong group definition in config file: {s} at line {d}", .{ path, line_number });
                };
                const group = std.mem.trimEnd(u8, line[1..close], whitespace);
                section = if (isWantedGroup(group)) .wanted else .other;
                continue;
            }
            switch (section) {
                .none => return self.fail("error: Found option without preceding group in config file: {s} at line: {d}", .{ path, line_number }),
                .other => {},
                .wanted => try self.addOption(line),
            }
        }
    }

    /// Handles `!include <file>` and `!includedir <dir>`. Other `!` lines are ignored, as in MariaDB.
    fn directive(self: *Loader, body: []const u8, path: []const u8, line_number: usize, depth: usize) Error!void {
        const rest = std.mem.trimStart(u8, body, whitespace);
        var kind: Directive = undefined;
        var argument: []const u8 = undefined;
        if (afterKeyword(rest, "includedir")) |value| {
            kind = .includedir;
            argument = value;
        } else if (afterKeyword(rest, "include")) |value| {
            kind = .include;
            argument = value;
        } else {
            return;
        }

        const keyword = if (kind == .includedir) "includedir" else "include";
        if (argument.len == 0) {
            return self.fail("error: Wrong '!{s}' directive in config file: {s} at line {d}", .{ keyword, path, line_number });
        }
        if (depth >= max_include_depth) {
            self.stderr.print("Warning: skipping '!{s}' directive as maximum include recursion level was reached in file {s} at line {d}\n", .{ keyword, path, line_number }) catch {};
            return;
        }

        const target = try self.expandHome(argument);
        switch (kind) {
            .include => _ = try self.readFile(target, depth + 1),
            .includedir => try self.readDir(target, depth + 1),
        }
    }

    /// Reads every `*.cnf` file in `dir_path`, in name order, as MariaDB does.
    fn readDir(self: *Loader, dir_path: []const u8, depth: usize) Error!void {
        var dir = std.Io.Dir.openDir(.cwd(), self.io, dir_path, .{ .iterate = true }) catch {
            return self.fail("Could not read config directory: {s}", .{dir_path});
        };
        defer dir.close(self.io);

        var names: std.ArrayList([]const u8) = .empty;
        var iterator = dir.iterate();
        while (true) {
            const entry = (iterator.next(self.io) catch {
                return self.fail("Could not read config directory: {s}", .{dir_path});
            }) orelse break;
            if (std.mem.endsWith(u8, entry.name, ".cnf")) {
                try names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
            }
        }

        std.mem.sort([]const u8, names.items, {}, lessThanName);
        for (names.items) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ dir_path, name });
            _ = try self.readFile(path, depth);
        }
    }

    fn addOption(self: *Loader, line: []const u8) Error!void {
        const content = line[0..commentStart(line)];
        const equals = std.mem.indexOfScalar(u8, content, '=');
        const name = std.mem.trimEnd(u8, content[0 .. equals orelse content.len], whitespace);
        if (name.len == 0) {
            return;
        }
        const value: ?[]const u8 = if (equals) |index|
            try unescapeValue(self.allocator, content[index + 1 ..])
        else
            null;
        try self.settings.append(self.allocator, .{ .name = name, .value = value });
    }

    /// A leading "~/" means the home directory, as with the other path options.
    fn expandHome(self: *Loader, path: []const u8) Error![]const u8 {
        const home = self.home orelse return path;
        if (!std.mem.startsWith(u8, path, "~/")) {
            return path;
        }
        return std.fs.path.join(self.allocator, &.{ home, path[2..] });
    }

    /// Prints the message and returns the error. The caller does not print again.
    fn fail(self: *Loader, comptime format: []const u8, args: anytype) Error {
        self.stderr.print(format ++ "\n", args) catch {};
        return error.OptionFileFailed;
    }
};

/// The text after `keyword` when the keyword is followed by whitespace or the end. Null otherwise.
fn afterKeyword(text: []const u8, keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, keyword)) {
        return null;
    }
    const rest = text[keyword.len..];
    if (rest.len > 0 and !std.ascii.isWhitespace(rest[0])) {
        return null;
    }
    return std.mem.trim(u8, rest, whitespace);
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn testLoader(arena: *std.heap.ArenaAllocator, stderr: *std.Io.Writer) Loader {
    return .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .home = null,
        .stderr = stderr,
    };
}

fn expectSetting(setting: Setting, name: []const u8, value: ?[]const u8) !void {
    try std.testing.expectEqualStrings(name, setting.name);
    if (value) |expected| {
        try std.testing.expectEqualStrings(expected, setting.value.?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), setting.value);
    }
}

test "only the client groups are read, and group names ignore case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText(
        \\[client]
        \\user=a
        \\[server]
        \\user=server
        \\[MariaDB]
        \\host=h
        \\[mysqld]
        \\port=1
    , "test.cnf", 0);

    try std.testing.expectEqual(@as(usize, 2), loader.settings.items.len);
    try expectSetting(loader.settings.items[0], "user", "a");
    try expectSetting(loader.settings.items[1], "host", "h");
}

test "bare names have a null value, and an empty value stays empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText("[client]\nskip-column-names\nport=\n", "test.cnf", 0);
    try std.testing.expectEqual(@as(usize, 2), loader.settings.items.len);
    try expectSetting(loader.settings.items[0], "skip-column-names", null);
    try expectSetting(loader.settings.items[1], "port", "");
}

test "comments: whole lines, and a # after a value, but not inside quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText(
        \\[client]
        \\# a comment line
        \\; another comment line
        \\port=3306 # trailing comment
        \\password="a#b" # quoted hash is kept
        \\host=db;not-a-comment
    , "test.cnf", 0);

    try std.testing.expectEqual(@as(usize, 3), loader.settings.items.len);
    try expectSetting(loader.settings.items[0], "port", "3306");
    try expectSetting(loader.settings.items[1], "password", "a#b");
    try expectSetting(loader.settings.items[2], "host", "db;not-a-comment");
}

test "commentStart skips a hash inside quotes and honours an escaped quote" {
    try std.testing.expectEqual(@as(usize, 5), commentStart("port #x"));
    try std.testing.expectEqual(@as(usize, 7), commentStart("p=\"a#b\"#c"));
    // The backslash escapes the closing quote, so the hash at index 6 is still inside quotes.
    try std.testing.expectEqual(@as(usize, 10), commentStart("p='a\\'#b' #c"));
    try std.testing.expectEqual(@as(usize, 5), commentStart("p=ab #c"));
    try std.testing.expectEqual(@as(usize, 6), commentStart("p=\"x\" #c"));
    try std.testing.expectEqual(@as(usize, 3), commentStart("p=x"));
}

test "matching quotes are removed and mismatched quotes are kept" {
    const allocator = std.testing.allocator;

    const single = try unescapeValue(allocator, "  'hello world'  ");
    defer allocator.free(single);
    try std.testing.expectEqualStrings("hello world", single);

    const double = try unescapeValue(allocator, "\"it's\"");
    defer allocator.free(double);
    try std.testing.expectEqualStrings("it's", double);

    const mismatched = try unescapeValue(allocator, "'open\"");
    defer allocator.free(mismatched);
    try std.testing.expectEqualStrings("'open\"", mismatched);

    const lone = try unescapeValue(allocator, "\"");
    defer allocator.free(lone);
    try std.testing.expectEqualStrings("\"", lone);

    const empty_quotes = try unescapeValue(allocator, "\"\"");
    defer allocator.free(empty_quotes);
    try std.testing.expectEqualStrings("", empty_quotes);
}

test "escapes expand as in mysql.cc, unknown ones keep the backslash" {
    const allocator = std.testing.allocator;

    const known = try unescapeValue(allocator, "a\\tb\\nc\\rd\\be\\sf\\\\g\\\"h\\'i");
    defer allocator.free(known);
    try std.testing.expectEqualStrings("a\tb\nc\rd\x08e f\\g\"h'i", known);

    const unknown = try unescapeValue(allocator, "a\\xb");
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("a\\xb", unknown);

    const trailing = try unescapeValue(allocator, "end\\");
    defer allocator.free(trailing);
    try std.testing.expectEqualStrings("end\\", trailing);

    const quoted_escape = try unescapeValue(allocator, "\"say \\\"hi\\\"\"");
    defer allocator.free(quoted_escape);
    try std.testing.expectEqualStrings("say \"hi\"", quoted_escape);
}

test "escaped quotes inside quoted values are unescaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText("[client]\npassword='a\\'#b' # note\n", "test.cnf", 0);
    try std.testing.expectEqual(@as(usize, 1), loader.settings.items.len);
    try expectSetting(loader.settings.items[0], "password", "a'#b");
}

test "a value may contain '=', and the name ends at the first one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText("[client]\ninit-command = SET a=1\n", "test.cnf", 0);
    try expectSetting(loader.settings.items[0], "init-command", "SET a=1");
}

test "CRLF line endings and surrounding spaces are trimmed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText("  [client]  \r\n   user   =   root   \r\n\r\n", "test.cnf", 0);
    try std.testing.expectEqual(@as(usize, 1), loader.settings.items.len);
    try expectSetting(loader.settings.items[0], "user", "root");
}

test "an option before any group is an error, and the message names the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try std.testing.expectError(error.OptionFileFailed, loader.parseText("user=root\n", "bad.cnf", 0));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "without preceding group") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "bad.cnf at line: 1") != null);
}

test "an unterminated group header is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try std.testing.expectError(error.OptionFileFailed, loader.parseText("[client\nuser=root\n", "bad.cnf", 0));
}

test "unknown ! directives are ignored, and an include without a path is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText("[client]\n!frobnicate now\nuser=root\n", "test.cnf", 0);
    try std.testing.expectEqual(@as(usize, 1), loader.settings.items.len);

    try std.testing.expectError(error.OptionFileFailed, loader.parseText("[client]\n!include   \n", "test.cnf", 0));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "Wrong '!include' directive") != null);
}

test "includes and includedir read files in order, and skip non-.cnf files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Paths are relative to the working directory, as in client.zig's tests.
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(dir);
    const main_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/main.cnf", .{dir});
    defer std.testing.allocator.free(main_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "inc.cnf", .data = "[mariadb]\nhost=included\n" });
    try tmp.dir.createDirPath(io, "confd");
    try tmp.dir.writeFile(io, .{ .sub_path = "confd/b.cnf", .data = "[client]\nport=2\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "confd/a.cnf", .data = "[client]\nport=1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "confd/notes.txt", .data = "[client]\nport=9\n" });

    const main_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "[client]\nuser=root\n!include {s}/inc.cnf\n!includedir {s}/confd\n",
        .{ dir, dir },
    );
    defer std.testing.allocator.free(main_text);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.cnf", .data = main_text });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    _ = try loader.readFile(main_path, 0);
    try std.testing.expectEqual(@as(usize, 4), loader.settings.items.len);
    try expectSetting(loader.settings.items[0], "user", "root");
    try expectSetting(loader.settings.items[1], "host", "included");
    try expectSetting(loader.settings.items[2], "port", "1");
    try expectSetting(loader.settings.items[3], "port", "2");
}

test "a missing include is ignored, and a missing includedir is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    try loader.parseText("[client]\n!include /no/such/file.cnf\nuser=root\n", "test.cnf", 0);
    try std.testing.expectEqual(@as(usize, 1), loader.settings.items.len);

    try std.testing.expectError(error.OptionFileFailed, loader.parseText("[client]\n!includedir /no/such/config-dir\n", "test.cnf", 0));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "Could not read config directory") != null);
}

test "an include that includes itself stops at the recursion limit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(dir);
    const loop_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/loop.cnf", .{dir});
    defer std.testing.allocator.free(loop_path);
    const text = try std.fmt.allocPrint(std.testing.allocator, "[client]\nuser=loop\n!include {s}\n", .{loop_path});
    defer std.testing.allocator.free(text);
    try tmp.dir.writeFile(io, .{ .sub_path = "loop.cnf", .data = text });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [1024]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    var loader = testLoader(&arena, &stderr);

    _ = try loader.readFile(loop_path, 0);
    try std.testing.expect(loader.settings.items.len > 1);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "maximum include recursion level") != null);
}

test "leading defaults options are read only from the start of the command line" {
    const with_file = [_][]const u8{ "thysql", "--defaults-file=/tmp/a.cnf", "--defaults-extra-file=/tmp/b.cnf", "--print-defaults", "-h", "x" };
    const leading = try parseLeading(&with_file);
    try std.testing.expectEqualStrings("/tmp/a.cnf", leading.defaults_file.?);
    try std.testing.expectEqualStrings("/tmp/b.cnf", leading.extra_file.?);
    try std.testing.expect(leading.print_defaults);
    try std.testing.expectEqual(@as(usize, 4), leading.next);

    const none_first = [_][]const u8{ "thysql", "-u", "root", "--defaults-file=/tmp/a.cnf" };
    const late = try parseLeading(&none_first);
    try std.testing.expect(late.defaults_file == null);
    try std.testing.expectEqual(@as(usize, 1), late.next);

    const no_defaults = [_][]const u8{ "thysql", "--no-defaults", "root" };
    const bare = try parseLeading(&no_defaults);
    try std.testing.expect(bare.no_defaults);
    try std.testing.expectEqual(@as(usize, 2), bare.next);
}

test "a repeated defaults-file is misplaced" {
    const twice = [_][]const u8{ "thysql", "--defaults-file=/tmp/a.cnf", "--defaults-file=/tmp/b.cnf" };
    try std.testing.expectError(error.DefaultsOptionMisplaced, parseLeading(&twice));
}

test "leading-only option names are recognized with dashes or underscores" {
    try std.testing.expect(isLeadingOnly("no-defaults"));
    try std.testing.expect(isLeadingOnly("defaults_extra_file"));
    try std.testing.expect(isLeadingOnly("print-defaults"));
    try std.testing.expect(!isLeadingOnly("user"));
}

test "loose prefix and underscore equivalence are recognized" {
    try std.testing.expectEqualStrings("skip-column-names", withoutLoose("loose-skip-column-names"));
    try std.testing.expectEqualStrings("skip_column_names", withoutLoose("loose_skip_column_names"));
    try std.testing.expectEqualStrings("port", withoutLoose("port"));
    try std.testing.expect(sameName("skip_column_names", "skip-column-names"));
    try std.testing.expect(!sameName("skip-column", "skip-column-names"));
}

test "print-defaults shows the settings and the remaining arguments, masking the password" {
    const settings = [_]Setting{
        .{ .name = "user", .value = "root" },
        .{ .name = "password", .value = "hunter2" },
        .{ .name = "skip_column_names", .value = null },
    };
    const rest = [_][]const u8{ "-h", "127.0.0.1", "db" };

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try renderPrintDefaults(&out, "thysql", &settings, &rest);
    try std.testing.expectEqualStrings(
        "thysql would have been started with the following arguments:\n" ++
            "--user=root --password=*** --skip_column_names -h 127.0.0.1 db \n",
        out.buffered(),
    );
}
