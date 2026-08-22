const std = @import("std");

pub const Ring = struct {
    gpa: std.mem.Allocator,
    kills: std.ArrayList(std.ArrayList(u8)),
    cur: usize,
    size: usize = 10,

    pub fn init(gpa: std.mem.Allocator) !Ring {
        return .{
            .gpa = gpa,
            .kills = try std.ArrayList(std.ArrayList(u8)).initCapacity(gpa, 10),
            .cur = 0,
        };
    }

    pub fn deinit(self: *Ring) void {
        for (self.kills.items) |*line| {
            line.deinit(self.gpa);
        }
        self.kills.deinit(self.gpa);
    }

    /// push a new line to the ring
    pub fn push(self: *Ring, line: []const u8, from: usize, to: usize, lastCommandWasKill: bool) !void {
        self.cur = 0;
        if (from == to) {
            return;
        }

        if (lastCommandWasKill and self.kills.items.len > 0) { // continue with a series of kills
            if (from < to) {
                try self.append(line[from..to]);
            } else {
                try self.prepend(line[to..from]);
            }
        } else {
            if (self.kills.items.len == self.size) {
                self.kills.items[0].deinit(self.gpa);
                std.mem.copyForwards(
                    std.ArrayList(u8),
                    self.kills.items[0 .. self.kills.items.len - 1],
                    self.kills.items[1..],
                );
                self.kills.items.len -= 1;
            }

            const buf = try self.copy(line, from, to);
            try self.kills.append(self.gpa, buf);
        }
        return;
    }

    pub fn get(self: *Ring) ?[]u8 {
        if (self.kills.items.len == 0) {
            return null;
        }
        const line = self.kills.items[self.kills.items.len - 1 - self.cur];
        return line.items;
    }

    pub fn yankPop(self: *Ring) bool {
        if (self.kills.items.len == 0) {
            return false;
        }
        self.cur = (self.cur + 1) % self.kills.items.len;
        return true;
    }

    fn append(self: *Ring, buf: []const u8) !void {
        if (self.kills.items.len == 0) {
            return error.RingIsEmpty;
        }
        const line = &self.kills.items[self.kills.items.len - 1];
        return line.appendSlice(self.gpa, buf);
    }

    fn prepend(self: *Ring, buf: []const u8) !void {
        if (self.kills.items.len == 0) {
            return error.RingIsEmpty;
        }
        const line = &self.kills.items[self.kills.items.len - 1];
        return line.insertSlice(self.gpa, 0, buf);
    }

    fn copy(self: *Ring, line: []const u8, _from: usize, _to: usize) !std.ArrayList(u8) {
        const from = if (_from > _to) _to else _from;
        const to = if (_from > _to) _from else _to;
        // const length = to - from;
        var buf = try std.ArrayList(u8).initCapacity(self.gpa, 1024);
        try buf.appendSlice(self.gpa, line[from..to]);
        return buf;
    }
};

test "ring loads" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    ring.deinit();
}

test "consecutive kills append forward and prepend backward" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit();

    // Readline starts a new entry if the previous kill command killed no text
    // and consequently left the ring empty.
    try ring.push("one", 0, 3, true);
    try ring.push(" two", 0, 4, true);
    try ring.push("zero ", 5, 0, true);

    try std.testing.expectEqualStrings("zero one two", ring.get().?);
    try std.testing.expectEqual(@as(usize, 1), ring.kills.items.len);
}

test "yank pop cycles through differently sized kills and wraps" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit();

    try ring.push("oldest", 0, 6, false);
    try ring.push("x", 0, 1, false);
    try ring.push("most-recent", 0, 11, false);

    try std.testing.expectEqualStrings("most-recent", ring.get().?);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("x", ring.get().?);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("oldest", ring.get().?);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("most-recent", ring.get().?);
}

test "new kills retain history order and evict only the oldest" {
    const gpa = std.testing.allocator;
    var ring = try Ring.init(gpa);
    defer ring.deinit();
    ring.size = 3;

    try ring.push("oldest", 0, 6, false);
    try ring.push("second", 0, 6, false);
    try ring.push("third", 0, 5, false);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("second", ring.get().?);
    try ring.push("newest", 0, 6, false);

    try std.testing.expectEqual(@as(usize, 3), ring.kills.items.len);
    try std.testing.expectEqualStrings("newest", ring.get().?);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("third", ring.get().?);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("second", ring.get().?);
    try std.testing.expect(ring.yankPop());
    try std.testing.expectEqualStrings("newest", ring.get().?);
}
