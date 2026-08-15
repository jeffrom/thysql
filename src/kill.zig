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
        if (from == to) {
            return;
        }

        if (lastCommandWasKill) {
            if (from < to) {
                try self.append(line[from..to]);
            } else {
                try self.prepend(line[to..from]);
            }
        } else {
            // TODO rotate if we're at max len
            const buf = try self.copy(line, from, to);
            try self.kills.append(self.gpa, buf);
        }
        return;
    }

    fn append(self: *Ring, buf: []const u8) !void {
        if (self.kills.items.len == 0) {
            return error.RingIsEmpty;
        }
        var line = self.kills.items[self.kills.items.len - 1];
        return line.appendSlice(self.gpa, buf);
    }

    fn prepend(self: *Ring, buf: []const u8) !void {
        if (self.kills.items.len == 0) {
            return error.RingIsEmpty;
        }
        var line = self.kills.items[self.kills.items.len - 1];
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
