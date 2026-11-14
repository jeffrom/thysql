//! Where the REPL keeps its history, and the rules for finding it. The file itself is
//! read and written by replete's `FileHistory`, which `readline.zig` drives. The file
//! used to be written by isocline, one line per entry; `convertIsocline` brings it into
//! replete's format, where a statement can span several lines.

const std = @import("std");
const Io = std.Io;
const replete = @import("replete");

/// How the history file is read and written: at most `limit` statements, with an older
/// copy of a statement removed when it is entered again, as isocline did.
pub const options: replete.HistoryOptions = .{
    .limit = limit,
    .deduplication = .all,
    .write_timestamps = true,
};

pub const limit = 5000;

/// Resolves the history file: $MYSQL_HISTFILE, then $XDG_STATE_HOME/thysql/history,
/// then $HOME/.local/state/thysql/history. Empty variables count as unset.
/// Returns null when none of them is set. Caller frees the result.
pub fn historyPath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !?[:0]u8 {
    if (nonEmptyEnv(env, "MYSQL_HISTFILE")) |path| {
        return try allocator.dupeSentinel(u8, path, 0);
    }
    if (nonEmptyEnv(env, "XDG_STATE_HOME")) |state_home| {
        return try std.fs.path.joinZ(allocator, &.{ state_home, "thysql", "history" });
    }
    if (nonEmptyEnv(env, "HOME")) |home| {
        return try std.fs.path.joinZ(allocator, &.{ home, ".local", "state", "thysql", "history" });
    }
    return null;
}

fn nonEmptyEnv(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

test "history path prefers MYSQL_HISTFILE" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("MYSQL_HISTFILE", "/tmp/custom-history");
    try env.put("XDG_STATE_HOME", "/tmp/state");
    try env.put("HOME", "/tmp/home");

    const path = (try historyPath(allocator, &env)).?;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/custom-history", path);
}

test "history path falls back to XDG_STATE_HOME then HOME" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/home");
    try env.put("XDG_STATE_HOME", "/tmp/state");

    const xdg = (try historyPath(allocator, &env)).?;
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/tmp/state/thysql/history", xdg);

    try env.put("XDG_STATE_HOME", "");
    const home = (try historyPath(allocator, &env)).?;
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/tmp/home/.local/state/thysql/history", home);
}

test "history path is null without any location variable" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try std.testing.expect((try historyPath(allocator, &env)) == null);
}

/// Converts the history file at `path` from isocline's format, if it is in that format.
/// A missing file, an empty file, and a file that already starts with a `#<seconds>` record
/// are left alone. Every converted statement is dated now, since isocline kept no dates.
pub fn convertIsocline(allocator: std.mem.Allocator, io: Io, path: []const u8) !void {
    return convertIsoclineInDir(allocator, io, .cwd(), path);
}

pub fn convertIsoclineInDir(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) !void {
    const data = dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(data);

    const first_end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
    if (data.len == 0 or isTimestampRecord(data[0..first_end])) return;

    var history: replete.History = .init(allocator, options);
    defer history.deinit();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        // isocline never writes a raw `#` at the start of a line. It skips such lines on
        // load, so they are comments here too.
        if (raw.len == 0 or raw[0] == '#') continue;
        const entry = try decodeIsocline(allocator, raw);
        defer allocator.free(entry);
        if (entry.len == 0) continue;
        _ = try history.addNow(io, entry);
    }
    try history.writeFileToDir(io, dir, path);
}

/// Undoes isocline's escaping of one history line. isocline wrote `\\` for a backslash,
/// `\n` and `\t` for newline and tab, and `\xHH` for any other byte outside printable ASCII.
/// `\r` is dropped, as isocline drops it. Any other backslash is kept as written, where
/// isocline stopped loading the file.
fn decodeIsocline(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        const byte = raw[i];
        i += 1;
        if (byte == '\r') continue;
        if (byte != '\\' or i == raw.len) {
            try out.append(allocator, byte);
            continue;
        }
        switch (raw[i]) {
            'n' => try out.append(allocator, '\n'),
            't' => try out.append(allocator, '\t'),
            '\\' => try out.append(allocator, '\\'),
            'r' => {},
            'x' => if (i + 3 <= raw.len and std.ascii.isHex(raw[i + 1]) and std.ascii.isHex(raw[i + 2])) {
                const value = std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16) catch unreachable;
                try out.append(allocator, value);
                i += 2;
            } else {
                try out.appendSlice(allocator, "\\x");
            },
            else => {
                try out.append(allocator, '\\');
                try out.append(allocator, raw[i]);
            },
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// True for a `#<seconds>` record, the timestamp line that replete's format puts before each entry.
fn isTimestampRecord(line: []const u8) bool {
    if (line.len < 2 or line[0] != '#') return false;
    for (line[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

test "isocline escapes are decoded and unknown ones are kept" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "select 1\\nfrom t", "select 1\nfrom t" },
        .{ "a\\\\b", "a\\b" },
        .{ "tab\\tend", "tab\tend" },
        .{ "\\x41\\xc3\\xa9", "A\xc3\xa9" },
        .{ "keep\\q and \\x4", "keep\\q and \\x4" },
        .{ "dos line\r", "dos line" },
    };
    for (cases) |case| {
        const decoded = try decodeIsocline(allocator, case[0]);
        defer allocator.free(decoded);
        try std.testing.expectEqualStrings(case[1], decoded);
    }
}

test "an isocline history file converts to one timestamped entry per statement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{
        .sub_path = "history",
        .data = "select 1\\nfrom t\nSELECT '\\\\'\n# comment\ncaf\\xc3\\xa9\n",
    });
    try convertIsoclineInDir(allocator, io, tmp.dir, "history");

    var loaded: replete.History = .init(allocator, options);
    defer loaded.deinit();
    try loaded.readFileFromDir(io, tmp.dir, "history");
    try std.testing.expectEqual(@as(usize, 3), loaded.len());
    try std.testing.expectEqualStrings("select 1\nfrom t", loaded.get(0).?.line);
    try std.testing.expectEqualStrings("SELECT '\\'", loaded.get(1).?.line);
    try std.testing.expectEqualStrings("caf\xc3\xa9", loaded.get(2).?.line);
    try std.testing.expect(loaded.get(0).?.timestamp > 0);
}

test "a history file already in replete's format is left as it is" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const text = "#1700000000\nselect\n1\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "history", .data = text });
    try convertIsoclineInDir(allocator, io, tmp.dir, "history");

    const after = try tmp.dir.readFileAlloc(io, "history", allocator, .limited(1024));
    defer allocator.free(after);
    try std.testing.expectEqualStrings(text, after);
}

test "a missing history file is not an error to convert" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try convertIsoclineInDir(allocator, std.testing.io, tmp.dir, "absent");
}
