//! Names for tab completion in the REPL: the database, table, and column names of the
//! current database. The SQL keywords and functions come from `sql/keywords.zig`. The names are loaded on connect and
//! on `use`, and by `rehash`, as mysql.cc's build_completion_hash does. A column
//! is offered by its own name and as `table.column`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mysql = @import("mysql.zig");

/// The names of the current database, owned, without duplicates.
pub const Names = struct {
    allocator: Allocator,
    /// Every name, in the order it was added.
    words: std.ArrayList([:0]u8) = .empty,
    /// The same strings as `words`, for de-duplication. The keys are the owned copies.
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator) Names {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Names) void {
        self.clear();
        self.words.deinit(self.allocator);
        self.seen.deinit(self.allocator);
    }

    pub fn clear(self: *Names) void {
        for (self.words.items) |word| {
            self.allocator.free(word);
        }
        self.words.clearRetainingCapacity();
        self.seen.clearRetainingCapacity();
    }

    /// Adds `word` unless it is empty or already present.
    pub fn add(self: *Names, word: []const u8) !void {
        if (word.len == 0 or self.seen.contains(word)) {
            return;
        }
        const owned = try self.allocator.dupeSentinel(u8, word, 0);
        errdefer self.allocator.free(owned);
        try self.words.append(self.allocator, owned);
        errdefer _ = self.words.pop();
        try self.seen.put(self.allocator, owned, {});
    }

    /// Adds a column as `column` and as `table.column`, as mysql.cc does.
    pub fn addColumn(self: *Names, table: []const u8, column: []const u8) !void {
        try self.add(column);
        var buffer: [256]u8 = undefined;
        const qualified = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ table, column }) catch return;
        try self.add(qualified);
    }

    /// Replaces the names with those of the current database. Returns the number of
    /// tables, so the caller can decide whether to print a notice. A failed query
    /// leaves its names out, and the session carries on.
    pub fn load(self: *Names, db: *Mysql.DB) !u32 {
        self.clear();

        if (try db.rowsCopy(self.allocator, "SHOW DATABASES")) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |name| try self.add(name);
            }
        }

        var table_count: u32 = 0;
        if (try db.rowsCopy(self.allocator, "SHOW TABLES")) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |name| {
                    try self.add(name);
                    table_count += 1;
                }
            }
        }

        const columns_sql = "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE()";
        if (try db.rowsCopy(self.allocator, columns_sql)) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |table| {
                    if (row[1]) |column| try self.addColumn(table, column);
                }
            }
        }

        return table_count;
    }
};

/// True when `candidate` starts with `prefix`, ignoring ASCII case.
pub fn matches(candidate: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(candidate, prefix);
}

test "names are unique and keep insertion order" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.add("people");
    try names.add("people");
    try names.add("");
    try names.add("orders");
    try std.testing.expectEqual(@as(usize, 2), names.words.items.len);
    try std.testing.expectEqualStrings("people", names.words.items[0]);
    try std.testing.expectEqualStrings("orders", names.words.items[1]);
}

test "a column is offered by its name and as table.column, once each" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.addColumn("people", "name");
    try names.addColumn("orders", "name");
    try names.addColumn("people", "name");
    try std.testing.expectEqual(@as(usize, 3), names.words.items.len);
    try std.testing.expectEqualStrings("people.name", names.words.items[1]);
    try std.testing.expectEqualStrings("name", names.words.items[0]);
    try std.testing.expectEqualStrings("orders.name", names.words.items[2]);
}

test "clear empties the names so they can be loaded again" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.add("people");
    names.clear();
    try std.testing.expectEqual(@as(usize, 0), names.words.items.len);
    try names.add("people");
    try std.testing.expectEqual(@as(usize, 1), names.words.items.len);
}

test "prefix matching ignores case and needs the prefix at the start" {
    try std.testing.expect(matches("SELECT", "sel"));
    try std.testing.expect(matches("people.name", "PEOPLE."));
    try std.testing.expect(!matches("people", "ople"));
    try std.testing.expect(matches("anything", ""));
}
