//! Connection files: named groups of settings, so that `-C main/ro` can stand for
//! a host, user, and so on. They live in `$XDG_CONFIG_HOME/thysql/connections`, or
//! `$HOME/.config/thysql/connections` when XDG_CONFIG_HOME is unset or empty.
//!
//! A connection is a regular file, named by its path below the root. A directory
//! may hold a `config` file with defaults for everything below it, and its
//! `default-conn` names the connection that the bare directory name stands for.
//! The settings come back as `OptionFile.Setting`s, so options.zig applies them as
//! it does my.cnf entries. Unlike my.cnf, an unknown key is an error, because these
//! files belong to thysql.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ConfigFile = @import("config_file.zig");
const OptionFile = @import("option_file.zig");
const options = @import("options.zig");
const prompt = @import("prompt.zig");

pub const Error = error{ ConnectionFailed, OutOfMemory };

/// `connection` is a file of settings. `directory` is a folder, which may have a `config` file.
pub const Kind = enum { connection, directory };

/// One name in a listing. `name` is relative to the root, such as "main/ro".
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

/// A connection after resolution. `settings` point into the arena, so keep this alive while they are used.
pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    /// The final name after any `default-conn`, such as "main/ro".
    name: []const u8,
    /// In the order they apply: the root `config`, then each directory's `config` from the root
    /// down, then the connection file. `default-conn` and `prompt-color` are not among them.
    settings: []const OptionFile.Setting,
    /// The colour of the prompt's connection tag, from the last `prompt-color` that applies, or
    /// null for no colour.
    prompt_color: ?prompt.Color,

    pub fn deinit(self: *Resolved) void {
        self.arena.deinit();
    }
};

const config_name = "config";
const default_conn_key = "default-conn";
const prompt_color_key = "prompt-color";
const max_file_size = 1024 * 1024;
const max_hops = 8;
const max_depth = 8;
const whitespace = " \t\r\n\x0b\x0c";

/// Options whose values are paths, so a leading "~/" means the home directory.
const path_ids = [_]options.Id{ .ssl_ca, .ssl_capath, .ssl_cert, .ssl_key, .ssl_crl, .ssl_crlpath, .socket, .tee };

/// Finds the connection that `name` names. Follows `default-conn`, and collects the settings.
/// Errors are printed to `stderr` before `error.ConnectionFailed` is returned.
pub fn resolve(
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    stderr: *std.Io.Writer,
    name: []const u8,
) Error!Resolved {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const root = (try rootDir(allocator, env)) orelse {
        stderr.print("no connection named \"{s}\"\n", .{name}) catch {};
        return error.ConnectionFailed;
    };
    const found = try resolveIn(.{
        .allocator = allocator,
        .io = io,
        .root = root,
        .home = nonEmpty(env.get("HOME")),
        .stderr = stderr,
    }, name);
    // The name can point into `name`, which the caller may free, as the line of `\C` is. Copy it into the arena.
    const owned_name = try allocator.dupe(u8, found.name);
    return .{ .arena = arena, .name = owned_name, .settings = found.settings, .prompt_color = found.prompt_color };
}

/// The connection named by -C, if any, and the settings to parse with: the option-file settings
/// `base`, then the connection's settings, so the connection wins. Free it with `deinit`.
pub const Selection = struct {
    gpa: Allocator,
    /// Null when -C was not given. Then `settings` is `base`, and nothing is owned.
    resolved: ?Resolved = null,
    /// `base` followed by the connection's settings. Owned when `resolved` is set.
    settings: []const OptionFile.Setting,

    pub fn deinit(self: *Selection) void {
        if (self.resolved) |*resolved| {
            resolved.deinit();
            self.gpa.free(self.settings);
        }
        self.resolved = null;
    }

    /// The resolved name, such as "main/ro", or null without -C.
    pub fn name(self: *const Selection) ?[]const u8 {
        return if (self.resolved) |resolved| resolved.name else null;
    }

    /// The colour of the prompt's connection tag, or null without -C or without a `prompt-color`.
    pub fn promptColor(self: *const Selection) ?prompt.Color {
        return if (self.resolved) |resolved| resolved.prompt_color else null;
    }
};

/// Resolves the -C connection in `args[first..]` (see `options.connectionArg`). Resolution errors
/// are printed to `stderr` and `error.ConnectionFailed` is returned.
pub fn select(
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    stderr: *std.Io.Writer,
    args: []const []const u8,
    first: usize,
    base: []const OptionFile.Setting,
) Error!Selection {
    const requested = options.connectionArg(args, first) orelse return .{ .gpa = gpa, .settings = base };
    return selectName(gpa, io, env, stderr, requested, base);
}

/// Resolves the connection called `name`, as `-C name` does, with `base` before its settings. Errors
/// are printed to `stderr` as in `select`.
pub fn selectName(
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    stderr: *std.Io.Writer,
    name: []const u8,
    base: []const OptionFile.Setting,
) Error!Selection {
    var resolved = try resolve(gpa, io, env, stderr, name);
    errdefer resolved.deinit();

    const settings = try gpa.alloc(OptionFile.Setting, base.len + resolved.settings.len);
    @memcpy(settings[0..base.len], base);
    @memcpy(settings[base.len..], resolved.settings);
    return .{ .gpa = gpa, .resolved = resolved, .settings = settings };
}

/// Lists the entries directly in `dir`, a directory relative to the root ("" is the root),
/// sorted by name. Names are relative to the root, such as "main/ro". Hidden names and
/// `config` are skipped. A missing root or a `dir` that is not a directory gives an empty list.
pub fn list(
    allocator: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    dir: []const u8,
) Allocator.Error![]Entry {
    // The root path is scratch space. Only the entries outlive this call.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = (try rootDir(scratch.allocator(), env)) orelse return allocator.alloc(Entry, 0);
    const wanted = trimSlash(dir);
    if (wanted.len > 0 and !validName(wanted)) return allocator.alloc(Entry, 0);
    return listIn(allocator, io, root, wanted);
}

/// One connection name offered by `completions`: the text that replaces the typed word, and whether
/// a space follows it.
pub const Completion = struct {
    text: []const u8,
    space: bool,
};

/// The names that start with `typed`, for tab completion. A connection is offered by its name. A
/// directory is offered as `dir/`, with no space after it, and a directory with a `default-conn` is
/// also offered by its bare name. Allocated in `allocator`.
pub fn completions(
    allocator: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    typed: []const u8,
) Allocator.Error![]Completion {
    var out: std.ArrayList(Completion) = .empty;
    const dir = if (std.mem.lastIndexOfScalar(u8, typed, '/')) |slash| typed[0..slash] else "";
    const entries = try list(allocator, io, env, dir);
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.name, typed)) continue;
        switch (entry.kind) {
            .connection => try out.append(allocator, .{ .text = entry.name, .space = true }),
            .directory => {
                try out.append(allocator, .{ .text = try std.fmt.allocPrint(allocator, "{s}/", .{entry.name}), .space = false });
                if (try defaultConn(allocator, io, env, entry.name)) |_| {
                    try out.append(allocator, .{ .text = entry.name, .space = false });
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Every entry below the root, depth first: each directory is followed by what is in it. Names are
/// relative to the root. Used by `\C` to list the connections. Allocated in `allocator`.
pub fn listAll(allocator: Allocator, io: std.Io, env: *const std.process.Environ.Map) Allocator.Error![]Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = (try rootDir(scratch.allocator(), env)) orelse return allocator.alloc(Entry, 0);
    var out: std.ArrayList(Entry) = .empty;
    try allEntries(allocator, io, root, "", 0, &out);
    return out.toOwnedSlice(allocator);
}

/// The connections root: `$XDG_CONFIG_HOME/thysql/connections` when XDG_CONFIG_HOME is set
/// and non-empty, else `$HOME/.config/thysql/connections`. Null when neither is set.
pub fn rootDir(allocator: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    const folder = (try ConfigFile.dir(allocator, env)) orelse return null;
    return try std.fs.path.join(allocator, &.{ folder, "connections" });
}

/// The `default-conn` of the directory `dir` (relative to the root, "" for the root), or null when it
/// has none. A file that cannot be read or parsed counts as having none; completion uses this and
/// must stay quiet. The result is allocated in `allocator`.
pub fn defaultConn(allocator: Allocator, io: std.Io, env: *const std.process.Environ.Map, dir: []const u8) Allocator.Error!?[]const u8 {
    const root = (try rootDir(allocator, env)) orelse return null;
    const config_path = if (dir.len == 0)
        try std.fs.path.join(allocator, &.{ root, config_name })
    else
        try std.fs.path.join(allocator, &.{ root, dir, config_name });

    var discard_buffer: [1]u8 = undefined;
    var discard = std.Io.Writer.Discarding.init(&discard_buffer);
    const ctx: Context = .{
        .allocator = allocator,
        .io = io,
        .root = root,
        .home = nonEmpty(env.get("HOME")),
        .stderr = &discard.writer,
    };
    const parsed = parseFile(ctx, config_path, .directory_config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ConnectionFailed => return null,
    };
    const config = parsed orelse return null;
    return config.default_conn;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len > 0) text else null;
}

/// Everything resolution needs. Tests pass their own root and home.
const Context = struct {
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    home: ?[]const u8,
    stderr: *std.Io.Writer,
};

const Found = struct {
    name: []const u8,
    settings: []const OptionFile.Setting,
    prompt_color: ?prompt.Color,
};

/// Which kind of file is being parsed. Only a directory's config may hold `default-conn`.
const FileRole = enum { root_config, directory_config, connection };

const Parsed = struct {
    settings: []const OptionFile.Setting,
    default_conn: ?[]const u8,
    /// The file's `prompt-color`, or null when it has none. The inner null is `none`, which turns the colour off.
    prompt_color: ?(?prompt.Color),
};

/// The settings of one connection, and the colour its prompt tag takes.
const Collected = struct {
    settings: []const OptionFile.Setting,
    prompt_color: ?prompt.Color,
};

fn resolveIn(ctx: Context, requested: []const u8) Error!Found {
    var name = try checkName(ctx, requested);
    var hops: usize = 0;
    while (true) {
        const path = try std.fs.path.join(ctx.allocator, &.{ ctx.root, name });
        const kind = (try statKind(ctx, path)) orelse return notFound(ctx, name);
        if (kind == .connection) break;

        const config_path = try std.fs.path.join(ctx.allocator, &.{ path, config_name });
        const config = try parseFile(ctx, config_path, .directory_config);
        const target = if (config) |parsed| parsed.default_conn else null;
        const next = target orelse return noDefaultConn(ctx, name);

        hops += 1;
        if (hops > max_hops) {
            ctx.stderr.print("default-conn for \"{s}\" does not reach a connection within {d} hops; check for a cycle\n", .{ requested, max_hops }) catch {};
            return error.ConnectionFailed;
        }
        name = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ name, next });
    }
    const collected = try collectSettings(ctx, name);
    return .{ .name = name, .settings = collected.settings, .prompt_color = collected.prompt_color };
}

/// The settings of `name`: the root config, the config of each directory on the way down, then the file.
/// The last `prompt-color` among them wins, so a file's colour overrides its directory's.
fn collectSettings(ctx: Context, name: []const u8) Error!Collected {
    var settings: std.ArrayList(OptionFile.Setting) = .empty;
    var prompt_color: ?prompt.Color = null;

    const root_config = try std.fs.path.join(ctx.allocator, &.{ ctx.root, config_name });
    if (try parseFile(ctx, root_config, .root_config)) |parsed| {
        try settings.appendSlice(ctx.allocator, parsed.settings);
        if (parsed.prompt_color) |choice| prompt_color = choice;
    }

    var dir_path = ctx.root;
    var rest = name;
    while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        dir_path = try std.fs.path.join(ctx.allocator, &.{ dir_path, rest[0..slash] });
        rest = rest[slash + 1 ..];
        const config_path = try std.fs.path.join(ctx.allocator, &.{ dir_path, config_name });
        if (try parseFile(ctx, config_path, .directory_config)) |parsed| {
            try settings.appendSlice(ctx.allocator, parsed.settings);
            if (parsed.prompt_color) |choice| prompt_color = choice;
        }
    }

    const file_path = try std.fs.path.join(ctx.allocator, &.{ ctx.root, name });
    const parsed = (try parseFile(ctx, file_path, .connection)) orelse return notFound(ctx, name);
    try settings.appendSlice(ctx.allocator, parsed.settings);
    if (parsed.prompt_color) |choice| prompt_color = choice;
    return .{ .settings = try settings.toOwnedSlice(ctx.allocator), .prompt_color = prompt_color };
}

/// Reads and parses one file. Returns null when it does not exist, which is not an error.
fn parseFile(ctx: Context, path: []const u8, role: FileRole) Error!?Parsed {
    const text = std.Io.Dir.readFileAlloc(.cwd(), ctx.io, path, ctx.allocator, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ctx.stderr.print("could not read \"{s}\"\n", .{path}) catch {};
            return error.ConnectionFailed;
        },
    };

    var settings: std.ArrayList(OptionFile.Setting) = .empty;
    var default_conn: ?[]const u8 = null;
    var file_prompt_color: ?(?prompt.Color) = null;
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const equals = std.mem.indexOfScalar(u8, line, '=');
        const key = std.mem.trim(u8, line[0 .. equals orelse line.len], whitespace);
        const value: ?[]const u8 = if (equals) |index|
            unquote(std.mem.trim(u8, line[index + 1 ..], whitespace))
        else
            null;

        if (OptionFile.sameName(key, default_conn_key)) {
            if (role != .directory_config) {
                return failAt(ctx, path, line_number, "default-conn is only allowed in a directory's config file", .{});
            }
            const target = value orelse return failAt(ctx, path, line_number, "\"{s}\" needs a value", .{key});
            if (target.len > 0 and !validName(target)) {
                return failAt(ctx, path, line_number, "invalid default-conn \"{s}\"", .{target});
            }
            // An empty value resets the key, so the directory has no default.
            default_conn = if (target.len > 0) target else null;
            continue;
        }

        // The prompt colour is not a connection option, so it is read here and never reaches options.zig.
        if (OptionFile.sameName(key, prompt_color_key)) {
            const color_name = value orelse return failAt(ctx, path, line_number, "\"{s}\" needs a value", .{key});
            file_prompt_color = parseColor(color_name) orelse {
                return failAt(ctx, path, line_number, "unknown prompt-color \"{s}\"; use a colour such as red or bright-red, or none", .{color_name});
            };
            continue;
        }

        // Passwords are prompted for by a bare `password`. A value is refused, so no
        // secret is kept in a file that may be shared or committed.
        if (OptionFile.sameName(key, "password")) {
            if (value) |text_value| {
                if (text_value.len > 0) {
                    return failAt(ctx, path, line_number, "passwords are not stored in connection files; use keychain = true or auth-command", .{});
                }
            }
            try settings.append(ctx.allocator, .{ .name = key, .value = value });
            continue;
        }

        const spec = findSpec(key) orelse {
            return failAt(ctx, path, line_number, "unknown key \"{s}\"", .{key});
        };
        if (spec.arg == .required and value == null) {
            return failAt(ctx, path, line_number, "\"{s}\" needs a value", .{key});
        }
        var final_value = value;
        if (value) |text_value| {
            if (isPathId(spec.id)) final_value = try expandHome(ctx, text_value);
        }
        try settings.append(ctx.allocator, .{ .name = key, .value = final_value });
    }

    return .{
        .settings = try settings.toOwnedSlice(ctx.allocator),
        .default_conn = default_conn,
        .prompt_color = file_prompt_color,
    };
}

/// The colour names that `prompt-color` takes: the eight ANSI colours, their `bright-` forms, and
/// `none`, which is the null colour. Null when the name is unknown. Dashes and underscores are the same.
fn parseColor(name: []const u8) ?(?prompt.Color) {
    if (OptionFile.sameName(name, "none")) return @as(?prompt.Color, null);
    for (std.enums.values(prompt.Color)) |color| {
        if (OptionFile.sameName(@tagName(color), name)) return color;
    }
    return null;
}

/// A connection key is any connection or output option, or an execution option, as in
/// options.zig. Help and version are not allowed here, and neither are `connection`, because a
/// connection cannot name another one, and `theme`, which the config file sets.
fn findSpec(key: []const u8) ?options.Spec {
    for (options.specs) |spec| {
        if (spec.group != .other and spec.id != .connection and spec.id != .theme and OptionFile.sameName(spec.long, key)) {
            return spec;
        }
    }
    return null;
}

fn isPathId(id: options.Id) bool {
    for (path_ids) |path_id| {
        if (path_id == id) return true;
    }
    return false;
}

/// Turns a leading "~/" into the home directory. Other values are returned unchanged.
fn expandHome(ctx: Context, value: []const u8) Allocator.Error![]const u8 {
    const home = ctx.home orelse return value;
    if (!std.mem.startsWith(u8, value, "~/")) return value;
    return std.fs.path.join(ctx.allocator, &.{ home, value[2..] });
}

/// Removes one pair of double quotes. Nothing inside them is unescaped.
fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return text[1 .. text.len - 1];
    }
    return text;
}

/// Trims one trailing slash, so `main/` names the same thing as `main`.
fn trimSlash(name: []const u8) []const u8 {
    if (name.len > 1 and name[name.len - 1] == '/') {
        return name[0 .. name.len - 1];
    }
    return name;
}

/// A name is one or more components joined by "/". A component may not be empty, may not
/// start with ".", and may not be `config`. This rules out "..", absolute paths, and hidden files.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.' or std.mem.eql(u8, part, config_name)) {
            return false;
        }
    }
    return true;
}

fn checkName(ctx: Context, requested: []const u8) Error![]const u8 {
    const name = trimSlash(requested);
    if (validName(name)) return name;
    ctx.stderr.print("invalid connection name \"{s}\"\n", .{requested}) catch {};
    return error.ConnectionFailed;
}

/// The kind of the path, following symlinks. Null when nothing is there.
fn statKind(ctx: Context, path: []const u8) Error!?Kind {
    const stat = std.Io.Dir.statFile(.cwd(), ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => {
            ctx.stderr.print("could not read \"{s}\"\n", .{path}) catch {};
            return error.ConnectionFailed;
        },
    };
    return if (stat.kind == .directory) .directory else .connection;
}

fn notFound(ctx: Context, name: []const u8) Error {
    ctx.stderr.print("no connection named \"{s}\"", .{name}) catch {};
    if (try suggest(ctx, name)) |match| {
        ctx.stderr.print("; did you mean \"{s}\"?", .{match}) catch {};
    }
    ctx.stderr.writeByte('\n') catch {};
    return error.ConnectionFailed;
}

/// The first connection with the same leaf name, or one edit away from `name`.
fn suggest(ctx: Context, name: []const u8) Error!?[]const u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try allConnections(ctx.allocator, ctx.io, ctx.root, "", 0, &all);
    std.mem.sort([]const u8, all.items, {}, lessThanName);
    const wanted_leaf = leaf(name);
    for (all.items) |candidate| {
        if (std.mem.eql(u8, leaf(candidate), wanted_leaf) or oneEditApart(candidate, name)) {
            return candidate;
        }
    }
    return null;
}

fn noDefaultConn(ctx: Context, name: []const u8) Error {
    const children = try listIn(ctx.allocator, ctx.io, ctx.root, name);
    if (children.len == 0) {
        ctx.stderr.print("connection directory \"{s}\" has no default-conn and no connections\n", .{name}) catch {};
        return error.ConnectionFailed;
    }
    ctx.stderr.print("connection directory \"{s}\" has no default-conn; pick one of: ", .{name}) catch {};
    for (children, 0..) |child, index| {
        if (index > 0) ctx.stderr.writeAll(", ") catch {};
        ctx.stderr.writeAll(leaf(child.name)) catch {};
        if (child.kind == .directory) ctx.stderr.writeByte('/') catch {};
    }
    ctx.stderr.writeByte('\n') catch {};
    return error.ConnectionFailed;
}

/// Reports `path:line: message` and returns the error. The path is shown as `~/...` under HOME.
fn failAt(ctx: Context, path: []const u8, line: usize, comptime format: []const u8, args: anytype) Error {
    writeLocation(ctx, path);
    ctx.stderr.print(":{d}: ", .{line}) catch {};
    ctx.stderr.print(format ++ "\n", args) catch {};
    return error.ConnectionFailed;
}

fn writeLocation(ctx: Context, path: []const u8) void {
    if (ctx.home) |home| {
        if (path.len > home.len and std.mem.startsWith(u8, path, home) and path[home.len] == '/') {
            ctx.stderr.print("~{s}", .{path[home.len..]}) catch {};
            return;
        }
    }
    ctx.stderr.print("{s}", .{path}) catch {};
}

fn leaf(name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[index + 1 ..];
}

/// True when `a` and `b` differ by one insertion, deletion, or substitution.
fn oneEditApart(a: []const u8, b: []const u8) bool {
    if (a.len > b.len) return oneEditApart(b, a);
    if (b.len - a.len > 1) return false;
    var index: usize = 0;
    while (index < a.len and a[index] == b[index]) : (index += 1) {}
    if (index == a.len) return true;
    if (a.len == b.len) return std.mem.eql(u8, a[index + 1 ..], b[index + 1 ..]);
    return std.mem.eql(u8, a[index..], b[index + 1 ..]);
}

/// Lists `dir` (relative to `root`, "" for the root). Entries are sorted by name, and their
/// names are relative to the root. Symlinks are followed to decide what an entry is.
fn listIn(allocator: Allocator, io: std.Io, root: []const u8, dir: []const u8) Allocator.Error![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    const path = if (dir.len == 0) root else try std.fs.path.join(allocator, &.{ root, dir });
    var handle = std.Io.Dir.openDir(.cwd(), io, path, .{ .iterate = true }) catch {
        return allocator.alloc(Entry, 0);
    };
    defer handle.close(io);

    var iterator = handle.iterate();
    while (true) {
        const raw = (iterator.next(io) catch break) orelse break;
        if (!visibleName(raw.name)) continue;
        const kind = entryKind(io, handle, raw.name, raw.kind) orelse continue;
        const name = if (dir.len == 0)
            try allocator.dupe(u8, raw.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, raw.name });
        try entries.append(allocator, .{ .name = name, .kind = kind });
    }
    std.mem.sort(Entry, entries.items, {}, lessThanEntry);
    return entries.toOwnedSlice(allocator);
}

/// Every entry at or below `dir`, depth first, down to `max_depth` levels of directories.
fn allEntries(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    dir: []const u8,
    depth: usize,
    out: *std.ArrayList(Entry),
) Allocator.Error!void {
    const entries = try listIn(allocator, io, root, dir);
    for (entries) |entry| {
        try out.append(allocator, entry);
        if (entry.kind == .directory and depth < max_depth) {
            try allEntries(allocator, io, root, entry.name, depth + 1, out);
        }
    }
}

/// Every connection at or below `dir`, down to `max_depth` levels of directories.
fn allConnections(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    dir: []const u8,
    depth: usize,
    out: *std.ArrayList([]const u8),
) Allocator.Error!void {
    const entries = try listIn(allocator, io, root, dir);
    for (entries) |entry| {
        switch (entry.kind) {
            .connection => try out.append(allocator, entry.name),
            .directory => if (depth < max_depth) {
                try allConnections(allocator, io, root, entry.name, depth + 1, out);
            },
        }
    }
}

/// Dotfiles and `config` are never connections. Names that start with "." are ignored, so
/// editor swap files and .DS_Store do not show up.
fn visibleName(name: []const u8) bool {
    return name.len > 0 and name[0] != '.' and !std.mem.eql(u8, name, config_name);
}

fn entryKind(io: std.Io, dir: std.Io.Dir, name: []const u8, raw: std.Io.File.Kind) ?Kind {
    return switch (raw) {
        .directory => .directory,
        .file => .connection,
        .sym_link => blk: {
            const stat = dir.statFile(io, name, .{}) catch break :blk null;
            break :blk switch (stat.kind) {
                .directory => .directory,
                .file => .connection,
                else => null,
            };
        },
        else => null,
    };
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn testContext(arena: *std.heap.ArenaAllocator, root: []const u8, home: ?[]const u8, stderr: *std.Io.Writer) Context {
    return .{
        .allocator = arena.allocator(),
        .io = std.testing.io,
        .root = root,
        .home = home,
        .stderr = stderr,
    };
}

/// Writes a file under the test's temporary directory, creating its parent directories.
fn writeTestFile(tmp: *std.testing.TmpDir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |dir| {
        try tmp.dir.createDirPath(std.testing.io, dir);
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

/// The connections root for a test's temporary directory, relative to the working directory.
fn tmpRoot(allocator: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

const Expected = struct { name: []const u8, value: ?[]const u8 };

fn expectSettings(actual: []const OptionFile.Setting, expected: []const Expected) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.name);
        if (want.value) |value| {
            try std.testing.expectEqualStrings(value, got.value.?);
        } else {
            try std.testing.expectEqual(@as(?[]const u8, null), got.value);
        }
    }
}

test "values may be quoted, a # after a value is kept, and spaces are trimmed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "local", "# a comment\n  host =  \"db.example.com\"  \n\nport=3306\ndatabase = app # not a comment\nuser = \"  spaced  \"\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const found = try resolveIn(testContext(&arena, root, null, &stderr), "local");
    try std.testing.expectEqualStrings("local", found.name);
    try expectSettings(found.settings, &.{
        .{ .name = "host", .value = "db.example.com" },
        .{ .name = "port", .value = "3306" },
        .{ .name = "database", .value = "app # not a comment" },
        .{ .name = "user", .value = "  spaced  " },
    });
}

test "a bare key is a flag, an empty value is kept, and - and _ are the same" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "local", "skip_ssl\nport =\ncolumn-names\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const found = try resolveIn(testContext(&arena, root, null, &stderr), "local");
    try expectSettings(found.settings, &.{
        .{ .name = "skip_ssl", .value = null },
        .{ .name = "port", .value = "" },
        .{ .name = "column-names", .value = null },
    });
}

test "a bare key that needs a value is an error with its line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "local", "user = a\nhost\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "local"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "local:2: \"host\" needs a value") != null);
}

test "a leading ~/ expands in path keys only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "local", "ssl-ca = ~/certs/ca.pem\nsocket=~/s.sock\ndatabase = ~/db\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const found = try resolveIn(testContext(&arena, root, "/home/test", &stderr), "local");
    try expectSettings(found.settings, &.{
        .{ .name = "ssl-ca", .value = "/home/test/certs/ca.pem" },
        .{ .name = "socket", .value = "/home/test/s.sock" },
        .{ .name = "database", .value = "~/db" },
    });
}

test "an unknown key names the file and line, with ~ for HOME" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, ".config/thysql/connections/main/ro", "host = db\nhots = x\n");
    const home = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(home);
    const root = try std.fmt.allocPrint(std.testing.allocator, "{s}/.config/thysql/connections", .{home});
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, home, &stderr), "main/ro"));
    try std.testing.expectEqualStrings(
        "~/.config/thysql/connections/main/ro:2: unknown key \"hots\"\n",
        stderr.buffered(),
    );
}

test "passwords with a value are refused, and a bare password means prompt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "secret", "password = hunter2\n");
    try writeTestFile(&tmp, "prompt", "password\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "secret"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "passwords are not stored in connection files; use keychain = true or auth-command") != null);

    const found = try resolveIn(testContext(&arena, root, null, &stderr), "prompt");
    try expectSettings(found.settings, &.{.{ .name = "password", .value = null }});
}

test "help is not a connection key, and default-conn is refused in a connection file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "help-key", "help\n");
    try writeTestFile(&tmp, "dc-in-file", "default-conn = ro\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "help-key"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "help-key:1: unknown key \"help\"") != null);

    stderr = .fixed(&buffer);
    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "dc-in-file"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "dc-in-file:1: default-conn is only allowed in a directory's config file") != null);
}

test "theme is not a connection key, since the config file sets it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "themed", "theme = catppuccin\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "themed"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "themed:1: unknown key \"theme\"") != null);
}

test "a connection file cannot name another connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "chained", "connection = other\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "chained"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "chained:1: unknown key \"connection\"") != null);
}

test "default-conn is refused in the root config, which has no directory to apply to" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "config", "default-conn = local\n");
    try writeTestFile(&tmp, "local", "host = a\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "local"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "config:1: default-conn is only allowed in a directory's config file") != null);
}

test "settings layer from the root config down to the file, and the file wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "config", "user = root_user\nhost = h0\nport = 1\n");
    try writeTestFile(&tmp, "main/config", "host = h1\nport = 2\n");
    try writeTestFile(&tmp, "main/eu/config", "port = 3\n");
    try writeTestFile(&tmp, "main/eu/ro", "user = ro_user\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const found = try resolveIn(testContext(&arena, root, null, &stderr), "main/eu/ro");
    try std.testing.expectEqualStrings("main/eu/ro", found.name);
    try expectSettings(found.settings, &.{
        .{ .name = "user", .value = "root_user" },
        .{ .name = "host", .value = "h0" },
        .{ .name = "port", .value = "1" },
        .{ .name = "host", .value = "h1" },
        .{ .name = "port", .value = "2" },
        .{ .name = "port", .value = "3" },
        .{ .name = "user", .value = "ro_user" },
    });
}

test "default-conn follows nested directories, and is not a setting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "main/config", "default-conn = eu\nhost = h1\n");
    try writeTestFile(&tmp, "main/eu/config", "default-conn = ro\n");
    try writeTestFile(&tmp, "main/eu/ro", "user = ro_user\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const found = try resolveIn(testContext(&arena, root, null, &stderr), "main");
    try std.testing.expectEqualStrings("main/eu/ro", found.name);
    try expectSettings(found.settings, &.{
        .{ .name = "host", .value = "h1" },
        .{ .name = "user", .value = "ro_user" },
    });
}

test "default-conn that never reaches a connection stops after the hop limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // x/config says default-conn = x, and so does x/x/config, and so on. Each hop goes one level deeper.
    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(std.testing.allocator);
    for (0..10) |_| {
        try sub.appendSlice(std.testing.allocator, "x/");
        const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}config", .{sub.items});
        defer std.testing.allocator.free(config_path);
        try writeTestFile(&tmp, config_path, "default-conn = x\n");
    }
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "x"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "does not reach a connection within 8 hops") != null);
}

test "a directory without default-conn lists its children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "main/config", "host = h\n");
    try writeTestFile(&tmp, "main/ro", "user = r\n");
    try writeTestFile(&tmp, "main/write", "user = w\n");
    try writeTestFile(&tmp, "main/eu/config", "port = 1\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "main"));
    try std.testing.expectEqualStrings(
        "connection directory \"main\" has no default-conn; pick one of: eu/, ro, write\n",
        stderr.buffered(),
    );
}

test "a missing name gets a suggestion when one is close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "local", "host = a\n");
    try writeTestFile(&tmp, "main/ro", "user = r\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    // Same leaf name in another directory.
    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "ro"));
    try std.testing.expectEqualStrings("no connection named \"ro\"; did you mean \"main/ro\"?\n", stderr.buffered());

    // One edit away.
    stderr = .fixed(&buffer);
    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "mian/ro"));
    try std.testing.expectEqualStrings("no connection named \"mian/ro\"; did you mean \"main/ro\"?\n", stderr.buffered());

    // Nothing close: no suggestion.
    stderr = .fixed(&buffer);
    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "zzz"));
    try std.testing.expectEqualStrings("no connection named \"zzz\"\n", stderr.buffered());
}

test "invalid names are rejected, and one trailing slash is allowed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "local", "host = a\n");
    try writeTestFile(&tmp, "main/ro", "user = r\n");
    try writeTestFile(&tmp, ".hidden", "host = a\n");
    try writeTestFile(&tmp, "main/.swp", "host = a\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    const bad_names = [_][]const u8{ "", "/local", "main/../local", "main//ro", "main/config", "config", ".hidden", "main/.swp", "main/ro//" };
    for (bad_names) |bad| {
        try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), bad));
    }
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "invalid connection name \"main/../local\"") != null);

    const found = try resolveIn(testContext(&arena, root, null, &stderr), "local/");
    try std.testing.expectEqualStrings("local", found.name);
}

test "list skips dotfiles and config, and includes directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "write", "host = a\n");
    try writeTestFile(&tmp, "local", "host = a\n");
    try writeTestFile(&tmp, ".DS_Store", "x\n");
    try writeTestFile(&tmp, "config", "host = a\n");
    try writeTestFile(&tmp, "main/config", "host = a\n");
    try writeTestFile(&tmp, "main/ro", "host = a\n");
    try writeTestFile(&tmp, "main/.ro.swp", "x\n");
    try writeTestFile(&tmp, "main/eu/ro", "host = a\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const top = try listIn(allocator, std.testing.io, root, "");
    try std.testing.expectEqual(@as(usize, 3), top.len);
    try std.testing.expectEqualStrings("local", top[0].name);
    try std.testing.expectEqual(Kind.connection, top[0].kind);
    try std.testing.expectEqualStrings("main", top[1].name);
    try std.testing.expectEqual(Kind.directory, top[1].kind);
    try std.testing.expectEqualStrings("write", top[2].name);

    const under_main = try listIn(allocator, std.testing.io, root, "main");
    try std.testing.expectEqual(@as(usize, 2), under_main.len);
    try std.testing.expectEqualStrings("main/eu", under_main[0].name);
    try std.testing.expectEqual(Kind.directory, under_main[0].kind);
    try std.testing.expectEqualStrings("main/ro", under_main[1].name);
    try std.testing.expectEqual(Kind.connection, under_main[1].kind);
}

test "the root is XDG_CONFIG_HOME when set and non-empty, else HOME" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(@as(?[]const u8, null), try rootDir(allocator, &env));

    try env.put("HOME", "/home/t");
    try std.testing.expectEqualStrings("/home/t/.config/thysql/connections", (try rootDir(allocator, &env)).?);

    try env.put("XDG_CONFIG_HOME", "");
    try std.testing.expectEqualStrings("/home/t/.config/thysql/connections", (try rootDir(allocator, &env)).?);

    try env.put("XDG_CONFIG_HOME", "/xdg");
    try std.testing.expectEqualStrings("/xdg/thysql/connections", (try rootDir(allocator, &env)).?);
}

test "resolve and list read the root from XDG_CONFIG_HOME" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "xdg/thysql/connections/local", "host = x\n");
    const xdg = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/xdg", .{&tmp.sub_path});
    defer std.testing.allocator.free(xdg);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", xdg);
    try env.put("HOME", "/nowhere");
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    var resolved = try resolve(std.testing.allocator, std.testing.io, &env, &stderr, "local");
    defer resolved.deinit();
    try std.testing.expectEqualStrings("local", resolved.name);
    try expectSettings(resolved.settings, &.{.{ .name = "host", .value = "x" }});

    const entries = try list(std.testing.allocator, std.testing.io, &env, "");
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    std.testing.allocator.free(entries[0].name);
    try std.testing.expectError(error.ConnectionFailed, resolve(std.testing.allocator, std.testing.io, &env, &stderr, "nope"));
}

test "select applies the connection after the given settings, and needs no -C without one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "xdg/thysql/connections/local", "host = from-file\nuser = file-user\n");
    const xdg = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/xdg", .{&tmp.sub_path});
    defer std.testing.allocator.free(xdg);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", xdg);
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const base = [_]OptionFile.Setting{.{ .name = "host", .value = "from-option-file" }};
    const with_c = [_][]const u8{ "thysql", "-C", "local" };
    var selected = try select(std.testing.allocator, std.testing.io, &env, &stderr, &with_c, 1, &base);
    defer selected.deinit();
    try std.testing.expectEqualStrings("local", selected.name().?);
    try expectSettings(selected.settings, &.{
        .{ .name = "host", .value = "from-option-file" },
        .{ .name = "host", .value = "from-file" },
        .{ .name = "user", .value = "file-user" },
    });

    const without_c = [_][]const u8{"thysql"};
    var plain = try select(std.testing.allocator, std.testing.io, &env, &stderr, &without_c, 1, &base);
    defer plain.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), plain.name());
    try std.testing.expectEqual(@as(usize, 1), plain.settings.len);
}

test "prompt-color names: each colour, its bright form, none, and - and _ are the same" {
    for (std.enums.values(prompt.Color)) |color| {
        try std.testing.expectEqual(color, parseColor(@tagName(color)).?.?);
    }
    try std.testing.expectEqual(prompt.Color.bright_cyan, parseColor("bright-cyan").?.?);
    try std.testing.expectEqual(prompt.Color.red, parseColor("red").?.?);
    try std.testing.expectEqual(@as(?prompt.Color, null), parseColor("none").?);
    try std.testing.expect(parseColor("purple") == null);
    try std.testing.expect(parseColor("") == null);
}

test "an invalid or bare prompt-color names the file and line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "purple", "host = a\nprompt-color = purple\n");
    try writeTestFile(&tmp, "bare", "host = a\nprompt-color\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "purple"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "purple:2: unknown prompt-color \"purple\"") != null);

    stderr = .fixed(&buffer);
    try std.testing.expectError(error.ConnectionFailed, resolveIn(testContext(&arena, root, null, &stderr), "bare"));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "bare:2: \"prompt-color\" needs a value") != null);
}

test "prompt-color is not a setting, and the nearest file or directory with one wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "config", "prompt-color = blue\nuser = root_user\n");
    try writeTestFile(&tmp, "main/config", "prompt-color = red\n");
    try writeTestFile(&tmp, "main/ro", "user = ro_user\n");
    try writeTestFile(&tmp, "main/eu/config", "prompt-color = none\n");
    try writeTestFile(&tmp, "main/eu/ro", "prompt-color = bright-green\n");
    try writeTestFile(&tmp, "main/eu/rw", "user = rw_user\n");
    try writeTestFile(&tmp, "other", "host = o\n");
    const root = try tmpRoot(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(root);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    const inherited = try resolveIn(testContext(&arena, root, null, &stderr), "main/ro");
    try std.testing.expectEqual(prompt.Color.red, inherited.prompt_color.?);
    try expectSettings(inherited.settings, &.{
        .{ .name = "user", .value = "root_user" },
        .{ .name = "user", .value = "ro_user" },
    });

    const own = try resolveIn(testContext(&arena, root, null, &stderr), "main/eu/ro");
    try std.testing.expectEqual(prompt.Color.bright_green, own.prompt_color.?);

    const reset = try resolveIn(testContext(&arena, root, null, &stderr), "main/eu/rw");
    try std.testing.expectEqual(@as(?prompt.Color, null), reset.prompt_color);

    const from_root = try resolveIn(testContext(&arena, root, null, &stderr), "other");
    try std.testing.expectEqual(prompt.Color.blue, from_root.prompt_color.?);
}

test "select carries the connection's prompt colour, and there is none without -C" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(&tmp, "xdg/thysql/connections/main/config", "prompt-color = yellow\n");
    try writeTestFile(&tmp, "xdg/thysql/connections/main/ro", "host = h\n");
    const xdg = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/xdg", .{&tmp.sub_path});
    defer std.testing.allocator.free(xdg);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", xdg);
    var buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);

    var selected = try selectName(std.testing.allocator, std.testing.io, &env, &stderr, "main/ro", &.{});
    defer selected.deinit();
    try std.testing.expectEqual(prompt.Color.yellow, selected.promptColor().?);

    var plain = try select(std.testing.allocator, std.testing.io, &env, &stderr, &.{"thysql"}, 1, &.{});
    defer plain.deinit();
    try std.testing.expectEqual(@as(?prompt.Color, null), plain.promptColor());
}
