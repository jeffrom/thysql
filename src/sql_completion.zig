//! Names for tab completion in the REPL: the databases, tables, routines, and the columns
//! of the current database. The SQL keywords and functions come from `sql/keywords.zig`.
//! The names are loaded on connect and on `use`, and by `rehash`, as mysql.cc's
//! build_completion_hash does. Tables and routines are loaded for every database, so that
//! `db.` can be completed; columns only for the current one, as mysql.cc does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mysql = @import("mysql.zig");

/// A table or view. Its columns are listed only when it is in the current database.
pub const Table = struct {
    /// The database that holds the table.
    schema: [:0]u8,
    name: [:0]u8,
    /// The column names, in table order.
    columns: std.ArrayList([:0]u8) = .empty,
};

/// A stored function or procedure.
pub const Routine = struct {
    schema: [:0]u8,
    name: [:0]u8,
};

/// The names the server holds, all owned. Names are unique within their list, as the
/// server keeps them. Names are compared without regard to ASCII case.
pub const Names = struct {
    allocator: Allocator,
    /// The current database, or null when there is none.
    database: ?[:0]u8 = null,
    databases: std.ArrayList([:0]u8) = .empty,
    tables: std.ArrayList(Table) = .empty,
    routines: std.ArrayList(Routine) = .empty,

    pub fn init(allocator: Allocator) Names {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Names) void {
        self.clear();
        self.databases.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.routines.deinit(self.allocator);
    }

    /// Forgets every name, so that they can be loaded again.
    pub fn clear(self: *Names) void {
        if (self.database) |name| self.allocator.free(name);
        self.database = null;
        freeWords(self.allocator, &self.databases);
        for (self.tables.items) |*table| {
            self.allocator.free(table.schema);
            self.allocator.free(table.name);
            freeWords(self.allocator, &table.columns);
        }
        self.tables.clearRetainingCapacity();
        for (self.routines.items) |routine| {
            self.allocator.free(routine.schema);
            self.allocator.free(routine.name);
        }
        self.routines.clearRetainingCapacity();
    }

    /// Sets the current database. An empty name means there is none.
    pub fn setDatabase(self: *Names, name: []const u8) !void {
        if (self.database) |old| self.allocator.free(old);
        self.database = null;
        if (name.len == 0) return;
        self.database = try self.allocator.dupeSentinel(u8, name, 0);
    }

    /// Adds a database. An empty name is skipped.
    pub fn addDatabase(self: *Names, name: []const u8) !void {
        if (name.len == 0) return;
        const owned = try self.allocator.dupeSentinel(u8, name, 0);
        errdefer self.allocator.free(owned);
        try self.databases.append(self.allocator, owned);
    }

    /// Adds a table or view of `schema`. A table that is already listed is skipped.
    pub fn addTable(self: *Names, schema: []const u8, name: []const u8) !void {
        if (schema.len == 0 or name.len == 0 or self.findTable(schema, name) != null) return;
        const owned_schema = try self.allocator.dupeSentinel(u8, schema, 0);
        errdefer self.allocator.free(owned_schema);
        const owned_name = try self.allocator.dupeSentinel(u8, name, 0);
        errdefer self.allocator.free(owned_name);
        try self.tables.append(self.allocator, .{ .schema = owned_schema, .name = owned_name });
    }

    /// Adds a column to the listed table `table` of `schema`. A table that is not listed
    /// gets no column.
    pub fn addColumn(self: *Names, schema: []const u8, table: []const u8, column: []const u8) !void {
        if (column.len == 0) return;
        for (self.tables.items) |*entry| {
            if (!matchesTable(entry, schema, table)) continue;
            const owned = try self.allocator.dupeSentinel(u8, column, 0);
            errdefer self.allocator.free(owned);
            try entry.columns.append(self.allocator, owned);
            return;
        }
    }

    /// Adds a stored function or procedure of `schema`.
    pub fn addRoutine(self: *Names, schema: []const u8, name: []const u8) !void {
        if (schema.len == 0 or name.len == 0) return;
        const owned_schema = try self.allocator.dupeSentinel(u8, schema, 0);
        errdefer self.allocator.free(owned_schema);
        const owned_name = try self.allocator.dupeSentinel(u8, name, 0);
        errdefer self.allocator.free(owned_name);
        try self.routines.append(self.allocator, .{ .schema = owned_schema, .name = owned_name });
    }

    /// The table `name` of `schema`, or of the current database when `schema` is null.
    /// Null when the table is not listed.
    pub fn findTable(self: *const Names, schema: ?[]const u8, name: []const u8) ?*const Table {
        const wanted = schema orelse (self.database orelse return null);
        for (self.tables.items) |*entry| {
            if (matchesTable(entry, wanted, name)) return entry;
        }
        return null;
    }

    /// Replaces the names with those of the server. Returns the number of tables in the
    /// current database, so the caller can decide whether to print a notice. A failed query
    /// leaves its names out, and the session carries on.
    pub fn load(self: *Names, db: *Mysql.DB) !u32 {
        self.clear();

        if (try db.rowsCopy(self.allocator, "SELECT DATABASE()")) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            if (rows.len > 0) {
                if (rows[0][0]) |name| try self.setDatabase(name);
            }
        }

        if (try db.rowsCopy(self.allocator, "SHOW DATABASES")) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |name| try self.addDatabase(name);
            }
        }

        const tables_sql = "SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.TABLES";
        if (try db.rowsCopy(self.allocator, tables_sql)) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |schema| {
                    if (row[1]) |name| try self.addTable(schema, name);
                }
            }
        }

        const routines_sql = "SELECT ROUTINE_SCHEMA, ROUTINE_NAME FROM information_schema.ROUTINES";
        if (try db.rowsCopy(self.allocator, routines_sql)) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |schema| {
                    if (row[1]) |name| try self.addRoutine(schema, name);
                }
            }
        }

        if (self.database) |current| {
            const columns_sql = "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS " ++
                "WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION";
            if (try db.rowsCopy(self.allocator, columns_sql)) |rows| {
                defer Mysql.freeRowsCopy(self.allocator, rows);
                for (rows) |row| {
                    if (row[0]) |table| {
                        if (row[1]) |column| try self.addColumn(current, table, column);
                    }
                }
            }
        }

        var table_count: u32 = 0;
        for (self.tables.items) |table| {
            if (self.database) |current| {
                if (std.ascii.eqlIgnoreCase(table.schema, current)) table_count += 1;
            }
        }
        return table_count;
    }
};

/// True when `table` is named `name` in `schema`, ignoring ASCII case.
fn matchesTable(table: *const Table, schema: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(table.schema, schema) and std.ascii.eqlIgnoreCase(table.name, name);
}

/// Frees the strings of `list` and the list itself, leaving it empty.
fn freeWords(allocator: Allocator, list: *std.ArrayList([:0]u8)) void {
    for (list.items) |word| allocator.free(word);
    list.deinit(allocator);
    list.* = .empty;
}

/// True when `candidate` starts with `prefix`, ignoring ASCII case.
pub fn matches(candidate: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(candidate, prefix);
}

test "a table is listed once, with its database" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.addTable("app", "people");
    try names.addTable("app", "people");
    try names.addTable("archive", "people");
    try std.testing.expectEqual(@as(usize, 2), names.tables.items.len);
    try std.testing.expectEqualStrings("archive", names.tables.items[1].schema);
}

test "a column belongs to its table in its database" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.addTable("app", "people");
    try names.addTable("archive", "people");
    try names.setDatabase("app");
    try names.addColumn("app", "people", "name");
    try names.addColumn("app", "people", "id");
    try names.addColumn("archive", "orders", "name");

    const current = names.findTable(null, "PEOPLE").?;
    try std.testing.expectEqual(@as(usize, 2), current.columns.items.len);
    try std.testing.expectEqualStrings("name", current.columns.items[0]);
    try std.testing.expectEqual(@as(usize, 0), names.findTable("archive", "people").?.columns.items.len);
    try std.testing.expect(names.findTable("archive", "orders") == null);
}

test "an unqualified table is looked up in the current database" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.addTable("archive", "people");
    try std.testing.expect(names.findTable(null, "people") == null);
    try names.setDatabase("archive");
    try std.testing.expect(names.findTable(null, "people") != null);
    try names.setDatabase("");
    try std.testing.expect(names.findTable(null, "people") == null);
}

test "clear empties the names so they can be loaded again" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    try names.addDatabase("app");
    try names.addTable("app", "people");
    try names.addColumn("app", "people", "name");
    try names.addRoutine("app", "total");
    try names.setDatabase("app");
    names.clear();
    try std.testing.expectEqual(@as(usize, 0), names.databases.items.len);
    try std.testing.expectEqual(@as(usize, 0), names.tables.items.len);
    try std.testing.expectEqual(@as(usize, 0), names.routines.items.len);
    try std.testing.expect(names.database == null);
    try names.addTable("app", "people");
    try std.testing.expectEqual(@as(usize, 1), names.tables.items.len);
}

test "prefix matching ignores case and needs the prefix at the start" {
    try std.testing.expect(matches("SELECT", "sel"));
    try std.testing.expect(matches("people.name", "PEOPLE."));
    try std.testing.expect(!matches("people", "ople"));
    try std.testing.expect(matches("anything", ""));
}
