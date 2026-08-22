const std = @import("std");
const Io = std.Io;

pub const Deduplication = enum {
    none,
    /// Do not add a line when it is identical to the newest entry.
    consecutive,
    /// Remove older identical entries before adding the new entry.
    all,
};

pub const Direction = enum { backward, forward };
pub const MatchMode = enum { substring, prefix };

pub const Options = struct {
    /// Null means unlimited history. Zero disables storage.
    limit: ?usize = null,
    deduplication: Deduplication = .none,
    /// Emit Readline's `#<unix-seconds>` records when writing a file.
    write_timestamps: bool = true,
};

pub const Entry = struct {
    line: []u8,
    /// Seconds since the Unix epoch. Zero means no timestamp was supplied.
    timestamp: i64,
};

pub const Match = struct {
    index: usize,
    offset: usize,
};

pub const History = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    options: Options,

    pub fn init(gpa: std.mem.Allocator, options: Options) History {
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *History) void {
        self.clear();
        self.entries.deinit(self.gpa);
    }

    pub fn clear(self: *History) void {
        for (self.entries.items) |entry| self.gpa.free(entry.line);
        self.entries.clearRetainingCapacity();
    }

    pub fn len(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const History, index: usize) ?*const Entry {
        if (index >= self.entries.items.len) return null;
        return &self.entries.items[index];
    }

    pub fn setLimit(self: *History, limit: ?usize) void {
        self.options.limit = limit;
        self.enforceLimit();
    }

    pub fn addNow(self: *History, io: Io, line: []const u8) !bool {
        return self.add(line, Io.Clock.real.now(io).toSeconds());
    }

    /// Adds a copied line. Returns false when deduplication or a zero limit
    /// suppresses it.
    pub fn add(self: *History, line: []const u8, timestamp: i64) !bool {
        if (self.options.limit == 0) return false;

        if (self.entries.items.len > 0 and
            self.options.deduplication == .consecutive and
            std.mem.eql(u8, self.entries.items[self.entries.items.len - 1].line, line))
        {
            return false;
        }

        const copy = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(copy);
        try self.entries.ensureUnusedCapacity(self.gpa, 1);

        if (self.options.deduplication == .all) {
            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (std.mem.eql(u8, self.entries.items[i].line, line)) {
                    self.removeAt(i);
                } else {
                    i += 1;
                }
            }
        }

        self.entries.appendAssumeCapacity(.{ .line = copy, .timestamp = timestamp });
        self.enforceLimit();
        return true;
    }

    /// Replaces an entry without changing its timestamp.
    pub fn replace(self: *History, index: usize, line: []const u8) !bool {
        if (index >= self.entries.items.len) return false;
        const copy = try self.gpa.dupe(u8, line);
        self.gpa.free(self.entries.items[index].line);
        self.entries.items[index].line = copy;
        return true;
    }

    pub fn find(
        self: *const History,
        query: []const u8,
        start: usize,
        direction: Direction,
        mode: MatchMode,
    ) ?Match {
        if (self.entries.items.len == 0 or start >= self.entries.items.len) return null;
        var i = start;
        while (true) {
            const line = self.entries.items[i].line;
            const offset: ?usize = switch (mode) {
                .substring => std.mem.indexOf(u8, line, query),
                .prefix => if (std.mem.startsWith(u8, line, query)) 0 else null,
            };
            if (offset) |at| return .{ .index = i, .offset = at };

            switch (direction) {
                .backward => {
                    if (i == 0) return null;
                    i -= 1;
                },
                .forward => {
                    i += 1;
                    if (i == self.entries.items.len) return null;
                },
            }
        }
    }

    /// Reads the history format. Timestamp records also delimit multiline
    /// entries. Files without timestamps are interpreted linewise.
    pub fn readFile(self: *History, io: Io, path: []const u8) !void {
        return self.readFileFromDir(io, .cwd(), path);
    }

    pub fn readFileFromDir(self: *History, io: Io, dir: Io.Dir, path: []const u8) !void {
        const data = try dir.readFileAlloc(io, path, self.gpa, .limited(64 * 1024 * 1024));
        defer self.gpa.free(data);
        if (data.len == 0) return;

        const content = if (std.mem.endsWith(u8, data, "\n")) data[0 .. data.len - 1] else data;
        var lines = std.mem.splitScalar(u8, content, '\n');
        const first = trimCr(lines.first());
        const timestamped = parseTimestamp(first) != null;

        if (!timestamped) {
            if (first.len > 0) _ = try self.add(first, 0);
            while (lines.next()) |raw| {
                const line = trimCr(raw);
                if (line.len > 0) _ = try self.add(line, 0);
            }
            return;
        }

        var timestamp = parseTimestamp(first).?;
        var command: std.ArrayList(u8) = .empty;
        defer command.deinit(self.gpa);
        while (lines.next()) |raw| {
            const line = trimCr(raw);
            if (parseTimestamp(line)) |next_timestamp| {
                if (command.items.len > 0) _ = try self.add(command.items, timestamp);
                command.clearRetainingCapacity();
                timestamp = next_timestamp;
            } else {
                if (command.items.len > 0) try command.append(self.gpa, '\n');
                try command.appendSlice(self.gpa, line);
            }
        }
        if (command.items.len > 0) _ = try self.add(command.items, timestamp);
    }

    pub fn writeFile(self: *const History, io: Io, path: []const u8) !void {
        return self.writeFileToDir(io, .cwd(), path);
    }

    pub fn writeFileToDir(self: *const History, io: Io, dir: Io.Dir, path: []const u8) !void {
        var atomic = try dir.createFileAtomic(io, path, .{
            .permissions = .fromMode(0o600),
            .replace = true,
        });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var file_writer = atomic.file.writer(io, &buffer);
        try self.writeEntries(&file_writer.interface, 0);
        try file_writer.interface.flush();
        try atomic.replace(io);
    }

    /// Appends the newest `count` entries to an existing file.
    pub fn appendFile(self: *const History, io: Io, path: []const u8, count: usize) !void {
        return self.appendFileToDir(io, .cwd(), path, count);
    }

    pub fn appendFileToDir(self: *const History, io: Io, dir: Io.Dir, path: []const u8, count: usize) !void {
        var data: Io.Writer.Allocating = .init(self.gpa);
        defer data.deinit();
        const start = self.entries.items.len -| @min(count, self.entries.items.len);
        try self.writeEntries(&data.writer, start);

        var file = try dir.createFile(io, path, .{ .truncate = false });
        defer file.close(io);
        try file.writePositionalAll(io, data.written(), try file.length(io));
    }

    fn writeEntries(self: *const History, writer: *Io.Writer, start: usize) !void {
        for (self.entries.items[start..]) |entry| {
            if (self.options.write_timestamps and entry.timestamp != 0) {
                try writer.print("#{d}\n", .{entry.timestamp});
            }
            try writer.writeAll(entry.line);
            try writer.writeByte('\n');
        }
    }

    fn enforceLimit(self: *History) void {
        const limit = self.options.limit orelse return;
        while (self.entries.items.len > limit) self.removeAt(0);
    }

    fn removeAt(self: *History, index: usize) void {
        self.gpa.free(self.entries.items[index].line);
        _ = self.entries.orderedRemove(index);
    }
};

fn trimCr(line: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line;
}

fn parseTimestamp(line: []const u8) ?i64 {
    if (line.len < 2 or line[0] != '#') return null;
    for (line[1..]) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(i64, line[1..], 10) catch null;
}

test "limits and deduplication retain the newest entries" {
    var history = History.init(std.testing.allocator, .{ .limit = 3, .deduplication = .all });
    defer history.deinit();

    _ = try history.add("one", 1);
    _ = try history.add("two", 2);
    _ = try history.add("one", 3);
    _ = try history.add("three", 4);
    _ = try history.add("four", 5);

    try std.testing.expectEqual(@as(usize, 3), history.len());
    try std.testing.expectEqualStrings("one", history.get(0).?.line);
    try std.testing.expectEqualStrings("three", history.get(1).?.line);
    try std.testing.expectEqualStrings("four", history.get(2).?.line);
}

test "search supports direction, substrings, and prefixes" {
    var history = History.init(std.testing.allocator, .{});
    defer history.deinit();
    _ = try history.add("git status", 1);
    _ = try history.add("zig build", 2);
    _ = try history.add("git diff", 3);

    try std.testing.expectEqual(@as(usize, 2), history.find("git", 2, .backward, .prefix).?.index);
    try std.testing.expectEqual(@as(usize, 1), history.find("build", 0, .forward, .substring).?.index);
    try std.testing.expectEqual(@as(?Match, null), history.find("status", 1, .forward, .prefix));
}

test "replacing a history entry preserves its timestamp" {
    var history = History.init(std.testing.allocator, .{});
    defer history.deinit();
    _ = try history.add("before", 42);
    try std.testing.expect(try history.replace(0, "after"));
    try std.testing.expectEqualStrings("after", history.get(0).?.line);
    try std.testing.expectEqual(@as(i64, 42), history.get(0).?.timestamp);
}

test "Readline history files round-trip timestamps and multiline entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var written = History.init(std.testing.allocator, .{ .write_timestamps = true });
    defer written.deinit();
    _ = try written.add("first", 100);
    _ = try written.add("two\nlines", 200);
    try written.writeFileToDir(io, tmp.dir, "history");

    const bytes = try tmp.dir.readFileAlloc(io, "history", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("#100\nfirst\n#200\ntwo\nlines\n", bytes);

    var loaded = History.init(std.testing.allocator, .{});
    defer loaded.deinit();
    try loaded.readFileFromDir(io, tmp.dir, "history");
    try std.testing.expectEqual(@as(usize, 2), loaded.len());
    try std.testing.expectEqualStrings("two\nlines", loaded.get(1).?.line);
    try std.testing.expectEqual(@as(i64, 200), loaded.get(1).?.timestamp);
}

test "plain history files load one non-empty entry per line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "history", .data = "one\r\n\ntwo\n" });

    var history = History.init(std.testing.allocator, .{});
    defer history.deinit();
    try history.readFileFromDir(io, tmp.dir, "history");
    try std.testing.expectEqual(@as(usize, 2), history.len());
    try std.testing.expectEqualStrings("one", history.get(0).?.line);
    try std.testing.expectEqualStrings("two", history.get(1).?.line);
}

test "appendFile appends only the requested newest entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "history", .data = "existing\n" });

    var history = History.init(std.testing.allocator, .{ .write_timestamps = false });
    defer history.deinit();
    _ = try history.add("one", 1);
    _ = try history.add("two", 2);
    try history.appendFileToDir(io, tmp.dir, "history", 1);

    const bytes = try tmp.dir.readFileAlloc(io, "history", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("existing\ntwo\n", bytes);
}
