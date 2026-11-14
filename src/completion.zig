//! `thysql complete -- <word0> <word1> ... <wordN>`: the completion engine that shell scripts call.
//!
//! The words are the command line as the shell split it. `word0` is the program name, and
//! `wordN` is the word being completed, which may be empty. Nothing after the cursor is passed.
//!
//! Output is zero or more candidates, one per line, then a last line `:<directive>`. The
//! directive is a bit mask: 1 means no space after the candidate, 2 means the shell should
//! also complete filenames, and 4 means it should complete directory names.
//!
//! Exit status is always 0. Stderr is empty unless THYSQL_COMPLETE_DEBUG=1, which says why
//! nothing was offered.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Connections = @import("connections.zig");
const Mysql = @import("mysql.zig");
const OptionFile = @import("option_file.zig");
const Options = @import("options.zig");
const Password = @import("password.zig");

pub const directive_nospace: u8 = 1;
pub const directive_files: u8 = 2;
pub const directive_dirs: u8 = 4;

const debug_env = "THYSQL_COMPLETE_DEBUG";
/// Used for --connect-timeout when the command line does not give one.
const connect_timeout_seconds: u32 = 2;
/// An auth command that runs longer than this gives no candidates.
const command_timeout_ms: u64 = 5000;

const subcommands = [_][]const u8{ "complete", "completion", "keychain" };
const completion_shells = [_][]const u8{"bash"};
const keychain_verbs = [_][]const u8{ "delete", "set", "status" };
const protocol_values = [_][]const u8{ "socket", "tcp" };
const boolean_values = [_][]const u8{ "0", "1" };

/// What a flag's value is completed from. `none` means the value has no completion.
pub const ValueKind = enum { none, database, connection, file, dir, protocol, boolean };

/// A flag as the scanner sees it: whether it takes a value, and what kind of value.
const Flag = struct {
    arg: Options.ArgKind,
    kind: ValueKind,
};

/// Where the cursor is, as far as the completer needs to know.
pub const Context = struct {
    /// Put in front of each candidate, such as `--database=`. Empty for a separate word.
    wrapper: []const u8 = "",
    /// The part of the current word after the wrapper. Candidates must start with it.
    typed: []const u8 = "",
    /// Fixed candidates, filtered by `typed`.
    literals: []const []const u8 = &.{},
    /// Long option names, filtered by the whole word. A lone "-" also lists the short options.
    flag_names: bool = false,
    /// Database names from the server.
    databases: bool = false,
    /// Connection names from the connections directory.
    connections: bool = false,
    /// Directive bits that come with the context, such as `directive_files`.
    directive: u8 = 0,
};

/// What the words before the cursor leave open.
const Scan = struct {
    /// Words that are not options or option values, including the first one.
    positionals: usize = 0,
    /// True after a `--`: every later word is a positional.
    positional_only: bool = false,
    /// The option that is waiting for the word under the cursor as its value.
    pending: ?Flag = null,
};

/// One unit of the words before the cursor: an option with its value, or a single word.
const Group = struct {
    len: usize,
    positional: bool = false,
    pending: ?Flag = null,
};

/// Looks up a long option name. As in MariaDB, "-" and "_" are interchangeable.
fn findLong(name: []const u8) ?Flag {
    for (Options.specs) |spec| {
        if (OptionFile.sameName(spec.long, name)) return flagOf(spec);
    }
    // These are read before the other options and are not in the spec table, but they take a file.
    if (OptionFile.sameName(name, "defaults-file") or OptionFile.sameName(name, "defaults-extra-file")) {
        return .{ .arg = .required, .kind = .file };
    }
    return null;
}

fn findShort(flag: u8) ?Flag {
    for (Options.specs) |spec| {
        if (spec.short == flag) return flagOf(spec);
    }
    return null;
}

fn flagOf(spec: Options.Spec) Flag {
    return .{ .arg = spec.arg, .kind = kindOf(spec.id) };
}

fn kindOf(id: Options.Id) ValueKind {
    return switch (id) {
        .database => .database,
        .connection => .connection,
        .protocol => .protocol,
        .ssl, .ssl_verify_server_cert => .boolean,
        .ssl_ca, .ssl_cert, .ssl_key, .ssl_crl, .tee, .socket, .auth_command => .file,
        .ssl_capath, .ssl_crlpath => .dir,
        else => .none,
    };
}

/// True for a word that is a positional argument: anything not starting with "-", and a lone "-".
fn isPositionalWord(word: []const u8) bool {
    return word.len < 2 or word[0] != '-';
}

/// The group that starts at `words[i]`. A flag that takes a value and is the last word
/// before the cursor is `pending`: the word under the cursor is its value.
fn groupAt(words: []const []const u8, i: usize) Group {
    const word = words[i];
    if (isPositionalWord(word)) return .{ .len = 1, .positional = true };

    if (std.mem.startsWith(u8, word, "--")) {
        const body = word[2..];
        if (std.mem.indexOfScalar(u8, body, '=') != null) return .{ .len = 1 };
        const flag = findLong(body) orelse return .{ .len = 1 };
        return valueGroup(flag, i, words.len);
    }

    // A cluster of short flags. The first flag that takes a value ends the cluster, and
    // whatever follows it in the same word is its value.
    for (word[1..], 0..) |letter, offset| {
        const flag = findShort(letter) orelse return .{ .len = 1 };
        if (flag.arg == .none) continue;
        if (offset + 2 < word.len) return .{ .len = 1 };
        return valueGroup(flag, i, words.len);
    }
    return .{ .len = 1 };
}

fn valueGroup(flag: Flag, i: usize, count: usize) Group {
    if (flag.arg != .required) return .{ .len = 1 };
    if (i + 1 == count) return .{ .len = 1, .pending = flag };
    return .{ .len = 2 };
}

fn scan(words: []const []const u8) Scan {
    var result: Scan = .{};
    var i: usize = 0;
    while (i < words.len) {
        if (result.positional_only) {
            result.positionals += 1;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, words[i], "--")) {
            result.positional_only = true;
            i += 1;
            continue;
        }
        const group = groupAt(words, i);
        if (group.positional) result.positionals += 1;
        result.pending = group.pending;
        i += group.len;
    }
    return result;
}

/// The completion context for the word `cur`, after `words`. `words` excludes the program
/// name and `cur`.
pub fn context(words: []const []const u8, cur: []const u8) Context {
    const scanned = scan(words);
    if (scanned.pending) |flag| return valueContext(flag.kind, "", cur);
    if (!scanned.positional_only and cur.len > 0 and cur[0] == '-') return dashContext(cur);
    return positionalContext(words, scanned, cur);
}

/// A word that starts with "-": an option name, or an option with its value attached.
fn dashContext(cur: []const u8) Context {
    if (std.mem.startsWith(u8, cur, "--")) {
        if (std.mem.indexOfScalar(u8, cur, '=')) |equals| {
            const flag = findLong(cur[2..equals]) orelse return .{};
            return valueContext(flag.kind, cur[0 .. equals + 1], cur[equals + 1 ..]);
        }
        return .{ .flag_names = true, .typed = cur };
    }
    if (cur.len == 1) return .{ .flag_names = true, .typed = cur };

    const flag = findShort(cur[1]) orelse return .{};
    if (flag.arg == .none) return .{};
    return valueContext(flag.kind, cur[0..2], cur[2..]);
}

fn valueContext(kind: ValueKind, wrapper: []const u8, typed: []const u8) Context {
    return switch (kind) {
        .none => .{},
        .database => .{ .wrapper = wrapper, .typed = typed, .databases = true },
        .connection => .{ .wrapper = wrapper, .typed = typed, .connections = true },
        .file => .{ .directive = directive_files },
        .dir => .{ .directive = directive_dirs },
        .protocol => .{ .wrapper = wrapper, .typed = typed, .literals = &protocol_values },
        .boolean => .{ .wrapper = wrapper, .typed = typed, .literals = &boolean_values },
    };
}

/// A word that is a positional argument: a subcommand, a database, or a keychain connection.
fn positionalContext(words: []const []const u8, scanned: Scan, cur: []const u8) Context {
    if (words.len == 0) {
        return .{ .typed = cur, .literals = &subcommands, .databases = true };
    }

    const first_is_positional = isPositionalWord(words[0]);
    if (first_is_positional and std.mem.eql(u8, words[0], "keychain")) {
        if (scanned.positionals == 1) return .{ .typed = cur, .literals = &keychain_verbs, .connections = true };
        if (scanned.positionals == 2) return .{ .typed = cur, .connections = true };
        return .{};
    }
    if (first_is_positional and std.mem.eql(u8, words[0], "completion")) {
        if (scanned.positionals == 1) return .{ .typed = cur, .literals = &completion_shells };
        return .{};
    }
    if (scanned.positionals == 0) {
        return .{ .typed = cur, .databases = true };
    }
    return .{};
}

/// Collects candidates. Each candidate is allocated in `allocator`, which is an arena in `run`.
const Candidates = struct {
    allocator: Allocator,
    items: std.ArrayList([]const u8) = .empty,
    directive: u8 = 0,

    fn add(self: *Candidates, text: []const u8, nospace: bool) Allocator.Error!void {
        try self.items.append(self.allocator, text);
        if (nospace) self.directive |= directive_nospace;
    }

    /// Sorts the candidates and removes duplicates. Database names are added after this, in server order.
    fn sortUnique(self: *Candidates) void {
        std.mem.sort([]const u8, self.items.items, {}, lessThanText);
        var kept: usize = 0;
        for (self.items.items, 0..) |item, index| {
            if (index > 0 and std.mem.eql(u8, item, self.items.items[kept - 1])) continue;
            self.items.items[kept] = item;
            kept += 1;
        }
        self.items.shrinkRetainingCapacity(kept);
    }
};

fn lessThanText(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Adds long option names that start with `typed`, and short ones when `typed` is a lone "-".
/// A required value is shown as `--name=`, with no space after it.
fn addFlagNames(out: *Candidates, typed: []const u8) Allocator.Error!void {
    for (Options.specs) |spec| {
        const required = spec.arg == .required;
        const text = try std.fmt.allocPrint(out.allocator, "--{s}{s}", .{ spec.long, if (required) "=" else "" });
        if (std.mem.startsWith(u8, text, typed)) try out.add(text, required);

        if (typed.len == 1) {
            if (spec.short) |letter| {
                const short = try std.fmt.allocPrint(out.allocator, "-{c}", .{letter});
                try out.add(short, required);
            }
        }
    }
}

/// Adds literal values that start with `typed`, each with `wrapper` in front.
fn addLiterals(out: *Candidates, literals: []const []const u8, wrapper: []const u8, typed: []const u8) Allocator.Error!void {
    for (literals) |literal| {
        if (!std.mem.startsWith(u8, literal, typed)) continue;
        try out.add(try std.fmt.allocPrint(out.allocator, "{s}{s}", .{ wrapper, literal }), false);
    }
}

/// Adds connection names from the connections directory that start with `typed`. A directory
/// is offered as `dir/` with no space after it. A directory that has `default-conn` is also
/// offered by its bare name.
fn addConnections(out: *Candidates, io: std.Io, env: *const std.process.Environ.Map, wrapper: []const u8, typed: []const u8) Allocator.Error!void {
    const dir = if (std.mem.lastIndexOfScalar(u8, typed, '/')) |slash| typed[0..slash] else "";
    const entries = try Connections.list(out.allocator, io, env, dir);
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, typed)) continue;
        switch (entry.kind) {
            .connection => try out.add(try std.fmt.allocPrint(out.allocator, "{s}{s}", .{ wrapper, entry.name }), false),
            .directory => {
                try out.add(try std.fmt.allocPrint(out.allocator, "{s}{s}/", .{ wrapper, entry.name }), true);
                if (try Connections.defaultConn(out.allocator, io, env, entry.name)) |_| {
                    try out.add(try std.fmt.allocPrint(out.allocator, "{s}{s}", .{ wrapper, entry.name }), false);
                }
            },
        }
    }
}

/// The words that parse on their own, in order, with the program name first. A flag that does
/// not parse, or that is missing its value, is left out, so a half-typed flag does not hide the rest.
fn acceptedWords(allocator: Allocator, env: *const std.process.Environ.Map, words: []const []const u8) Options.Error![]const []const u8 {
    var accepted: std.ArrayList([]const u8) = .empty;
    errdefer accepted.deinit(allocator);
    try accepted.append(allocator, words[0]);

    var i: usize = 1;
    while (i < words.len) {
        const len = @min(groupAt(words, i).len, words.len - i);
        var trial: std.ArrayList([]const u8) = .empty;
        defer trial.deinit(allocator);
        try trial.appendSlice(allocator, accepted.items);
        try trial.appendSlice(allocator, words[i .. i + len]);

        if (Options.parseWithSettings(allocator, trial.items, 1, env, &.{})) |parsed| {
            var owned = parsed;
            owned.deinit(allocator);
            try accepted.appendSlice(allocator, words[i .. i + len]);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        }
        i += len;
    }
    return accepted.toOwnedSlice(allocator);
}

/// Adds the databases from the server that start with the typed value. It builds the options
/// from `argv` (program name, then the words before the cursor) as the REPL does, then connects
/// without asking for anything. A failure gives no candidates, and the reason goes to `stderr`.
fn addDatabases(
    out: *Candidates,
    io: std.Io,
    env: *const std.process.Environ.Map,
    stderr: *std.Io.Writer,
    debug: bool,
    argv: []const []const u8,
    ctx: Context,
) Allocator.Error!void {
    const allocator = out.allocator;
    var loaded = OptionFile.load(allocator, io, env, argv, stderr) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // OptionFile.load has already printed why.
        error.OptionFileFailed => return,
    };
    defer loaded.deinit();

    const accepted = acceptedWords(allocator, env, argv) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer allocator.free(accepted);

    var selection = Connections.select(allocator, io, env, stderr, accepted, 1, loaded.settings) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ConnectionFailed => {
            try note(stderr, "the -C connection does not resolve", .{});
            return;
        },
    };
    defer selection.deinit();

    var options = Options.parseWithSettings(allocator, accepted, 1, env, selection.settings) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try note(stderr, "the options do not parse: {s}", .{@errorName(err)});
            return;
        },
    };
    defer options.deinit(allocator);
    options.connection = selection.name();

    if (options.password_source == .prompt) {
        try note(stderr, "the password is a prompt, which completion does not ask for", .{});
        return;
    }
    if (options.connect_timeout == 0) options.connect_timeout = connect_timeout_seconds;

    var supplier: Password.Supplier = .{
        .allocator = allocator,
        .io = io,
        .source = options.password_source,
        .context = .{
            .interactive = false,
            .stderr = stderr,
            .env = env,
            .timeout_ms = command_timeout_ms,
            .discard_command_stderr = true,
        },
        .connection = options.connection orelse "",
        .fixed_reason = .complete,
    };
    defer supplier.deinit();

    var db = Mysql.DB.init(allocator, .{
        .host = options.host,
        .user = options.user,
        .password_provider = .{ .ctx = &supplier, .fetchFn = Password.Supplier.fetchOpaque },
        .database = "",
        .port = options.port,
        .socket = options.socket,
        .protocol = options.protocol,
        .tls = options.tls,
        .connect_timeout = options.connect_timeout,
        .quiet_connect_error = !debug,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try note(stderr, "cannot connect: {s}", .{@errorName(err)});
            return;
        },
    };
    defer db.close();

    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    db.renderDatabaseCompletions(&rendered.writer, ctx.typed) catch |err| {
        try note(stderr, "the database list failed: {s}", .{@errorName(err)});
        return;
    };
    var lines = std.mem.splitScalar(u8, rendered.written(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try out.add(try std.fmt.allocPrint(allocator, "{s}{s}", .{ ctx.wrapper, line }), false);
    }
}

/// Writes a line about why nothing was offered. `stderr` discards it unless debugging.
fn note(stderr: *std.Io.Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
    stderr.print("complete: " ++ format ++ "\n", args) catch {};
}

/// Builds the whole candidate list for the words after `complete --`.
fn complete(
    io: std.Io,
    env: *const std.process.Environ.Map,
    stderr: *std.Io.Writer,
    debug: bool,
    words: []const []const u8,
    out: *Candidates,
) Allocator.Error!void {
    // words[0] is the program name and words[last] is the word being completed.
    if (words.len < 2) return;
    const cur = words[words.len - 1];
    const before = words[1 .. words.len - 1];
    const ctx = context(before, cur);

    if (ctx.flag_names) try addFlagNames(out, ctx.typed);
    try addLiterals(out, ctx.literals, ctx.wrapper, ctx.typed);
    if (ctx.connections) try addConnections(out, io, env, ctx.wrapper, ctx.typed);
    out.sortUnique();
    out.directive |= ctx.directive;

    if (ctx.databases) {
        try addDatabases(out, io, env, stderr, debug, words[0 .. words.len - 1], ctx);
    }
}

/// The words after `complete`, with the `--` that separates them removed.
fn wordsAfterComplete(args: []const []const u8) []const []const u8 {
    const start: usize = if (args.len > 2 and std.mem.eql(u8, args[2], "--")) 3 else 2;
    return if (start < args.len) args[start..] else &.{};
}

/// Runs `thysql complete`. `args` is the whole argv, with `complete` at args[1].
pub fn run(
    allocator: Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    args: []const []const u8,
    env: *const std.process.Environ.Map,
) !u8 {
    const debug = if (env.get(debug_env)) |value| std.mem.eql(u8, value, "1") else false;
    var discard_buffer: [64]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);
    const diagnostics: *std.Io.Writer = if (debug) stderr else &discard.writer;

    // The candidates live in an arena, so every helper can allocate freely.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var out: Candidates = .{ .allocator = arena.allocator() };
    try complete(io, env, diagnostics, debug, wordsAfterComplete(args), &out);

    for (out.items.items) |item| {
        try stdout.print("{s}\n", .{item});
    }
    try stdout.print(":{d}\n", .{out.directive});
    try stdout.flush();
    return 0;
}

test "an empty first word offers the subcommands and databases" {
    const ctx = context(&.{}, "");
    try std.testing.expectEqual(true, ctx.databases);
    try std.testing.expectEqual(@as(usize, 3), ctx.literals.len);
    try std.testing.expectEqualStrings("complete", ctx.literals[0]);
    try std.testing.expectEqualStrings("keychain", ctx.literals[2]);
}

test "a lone dash or a dash and letters lists option names" {
    const dash = context(&.{ "-u", "root" }, "-");
    try std.testing.expect(dash.flag_names);
    try std.testing.expectEqualStrings("-", dash.typed);
    const long = context(&.{ "-u", "root" }, "--ss");
    try std.testing.expect(long.flag_names);
    try std.testing.expectEqualStrings("--ss", long.typed);
}

test "a long option with = completes its value, with the wrapper" {
    const protocol = context(&.{}, "--protocol=");
    try std.testing.expectEqualStrings("--protocol=", protocol.wrapper);
    try std.testing.expectEqualStrings("", protocol.typed);
    try std.testing.expectEqual(@as(usize, 2), protocol.literals.len);

    const boolean = context(&.{}, "--ssl-verify-server-cert=");
    try std.testing.expectEqualStrings("--ssl-verify-server-cert=", boolean.wrapper);
    try std.testing.expectEqual(@as(usize, 2), boolean.literals.len);
    try std.testing.expectEqualStrings("0", boolean.literals[0]);
}

test "a value that names a file or a directory sets the directive" {
    try std.testing.expectEqual(directive_files, context(&.{}, "--ssl-ca=").directive);
    try std.testing.expectEqual(directive_files, context(&.{"--ssl-cert"}, "").directive);
    try std.testing.expectEqual(directive_files, context(&.{}, "--auth-command=").directive);
    try std.testing.expectEqual(directive_files, context(&.{"--socket"}, "").directive);
    try std.testing.expectEqual(directive_files, context(&.{"--defaults-file"}, "").directive);
    try std.testing.expectEqual(directive_dirs, context(&.{}, "--ssl-capath=").directive);
    try std.testing.expectEqual(directive_dirs, context(&.{"--ssl-crlpath"}, "").directive);
}

test "a value option that is waiting for its value completes that value" {
    const ctx = context(&.{"--protocol"}, "");
    try std.testing.expectEqualStrings("", ctx.wrapper);
    try std.testing.expectEqual(@as(usize, 2), ctx.literals.len);

    const connection = context(&.{"-C"}, "ma");
    try std.testing.expect(connection.connections);
    try std.testing.expectEqualStrings("ma", connection.typed);
    try std.testing.expectEqualStrings("", connection.wrapper);
}

test "a short option with an attached value mirrors the attachment" {
    const database = context(&.{}, "-Dthy");
    try std.testing.expect(database.databases);
    try std.testing.expectEqualStrings("-D", database.wrapper);
    try std.testing.expectEqualStrings("thy", database.typed);

    const connection = context(&.{}, "-Cma");
    try std.testing.expect(connection.connections);
    try std.testing.expectEqualStrings("-C", connection.wrapper);
    try std.testing.expectEqualStrings("ma", connection.typed);
}

test "--connection= and --database= mirror the = form" {
    const connection = context(&.{}, "--connection=pre");
    try std.testing.expectEqualStrings("--connection=", connection.wrapper);
    try std.testing.expectEqualStrings("pre", connection.typed);

    const database = context(&.{}, "--database=thy");
    try std.testing.expectEqualStrings("--database=", database.wrapper);
    try std.testing.expectEqualStrings("thy", database.typed);
}

test "a separate database word is a database context with no wrapper" {
    const flag = context(&.{"-D"}, "thy");
    try std.testing.expect(flag.databases);
    try std.testing.expectEqualStrings("", flag.wrapper);
    try std.testing.expectEqualStrings("thy", flag.typed);

    const attached = context(&.{"-hlocalhost"}, "");
    try std.testing.expect(attached.databases);
}

test "an option that takes a value swallows the next word" {
    // -e takes "-D" as its SQL, so the word after it is the first positional: a database.
    const after_e = context(&.{ "-e", "-D" }, "thy");
    try std.testing.expect(after_e.databases);
    try std.testing.expectEqualStrings("", after_e.wrapper);

    // The word after -e is -e's value, not a database, so nothing is offered.
    const value_of_e = context(&.{"-e"}, "-D");
    try std.testing.expect(!value_of_e.databases);
    try std.testing.expectEqual(@as(u8, 0), value_of_e.directive);
}

test "after --, a dash word is a positional database name" {
    const ctx = context(&.{"--"}, "-x");
    try std.testing.expect(ctx.databases);
    try std.testing.expect(!ctx.flag_names);
    try std.testing.expectEqualStrings("-x", ctx.typed);
}

test "a flag whose value has no completion gives nothing" {
    const host = context(&.{"-h"}, "");
    try std.testing.expect(!host.databases and !host.connections and !host.flag_names);
    try std.testing.expectEqual(@as(u8, 0), host.directive);

    const attached = context(&.{}, "-pxyz");
    try std.testing.expect(!attached.databases and !attached.flag_names);

    const none = context(&.{}, "-s");
    try std.testing.expect(!none.flag_names and !none.databases);
}

test "keychain offers its verbs, then connection names" {
    const verb = context(&.{"keychain"}, "s");
    try std.testing.expectEqual(@as(usize, 3), verb.literals.len);
    try std.testing.expect(verb.connections);

    const name = context(&.{ "keychain", "set" }, "ma");
    try std.testing.expectEqual(@as(usize, 0), name.literals.len);
    try std.testing.expect(name.connections);
}

test "completion offers bash after its name" {
    const ctx = context(&.{"completion"}, "b");
    try std.testing.expectEqual(@as(usize, 1), ctx.literals.len);
    try std.testing.expectEqualStrings("bash", ctx.literals[0]);
}

test "flag names list every long option, and short ones for a lone dash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: Candidates = .{ .allocator = arena.allocator() };
    try addFlagNames(&out, "--ss");
    out.sortUnique();

    var saw_ssl = false;
    var saw_ssl_ca = false;
    for (out.items.items) |item| {
        if (std.mem.eql(u8, item, "--ssl")) saw_ssl = true;
        if (std.mem.eql(u8, item, "--ssl-ca=")) saw_ssl_ca = true;
        try std.testing.expect(std.mem.startsWith(u8, item, "--ss"));
    }
    try std.testing.expect(saw_ssl and saw_ssl_ca);
    // --ssl-ca= takes a value with no space after it, so the list asks for nospace.
    try std.testing.expectEqual(directive_nospace, out.directive);
}

test "a lone dash also lists short options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: Candidates = .{ .allocator = arena.allocator() };
    try addFlagNames(&out, "-");
    var saw_short = false;
    for (out.items.items) |item| {
        if (std.mem.eql(u8, item, "-h")) saw_short = true;
    }
    try std.testing.expect(saw_short);
}

test "a half-typed or unknown flag is left out of the accepted words" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = [_][]const u8{ "thysql", "-h", "db.example", "--no-such-flag", "-P", "abc", "-u", "root", "-D" };
    const accepted = try acceptedWords(arena.allocator(), &env, &words);
    try std.testing.expectEqual(@as(usize, 5), accepted.len);
    try std.testing.expectEqualStrings("-h", accepted[1]);
    try std.testing.expectEqualStrings("db.example", accepted[2]);
    try std.testing.expectEqualStrings("-u", accepted[3]);
    try std.testing.expectEqualStrings("root", accepted[4]);
}

test "run gives the candidates then the directive, and the words after -- are the command line" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stdout_buffer: [512]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const args = [_][]const u8{ "thysql", "complete", "--", "thysql", "--protocol=" };
    try std.testing.expectEqual(@as(u8, 0), try run(std.testing.allocator, std.testing.io, &stdout, &stderr, &args, &env));
    try std.testing.expectEqualStrings("--protocol=socket\n--protocol=tcp\n:0\n", stdout.buffered());
    try std.testing.expectEqualStrings("", stderr.buffered());
}
