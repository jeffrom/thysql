//! Names for tab completion in the REPL: the databases, tables, routines, and the columns
//! of the current database. The SQL keywords and functions come from `sql/keywords.zig`.
//! The names are loaded on connect and on `use`, and by `rehash`, as mysql.cc's
//! build_completion_hash does: the list of databases, and the tables, columns and routines of
//! the current one. The tables and routines of another database are loaded the first time
//! completion asks for them, after `db.`, so that a server with many databases connects as fast
//! as mysql.cc does. A statement that creates, drops, alters or renames something marks the names
//! stale, and the next Tab press loads them again; see `changesNames`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mysql = @import("mysql.zig");
const SqlLexer = @import("sql/lexer.zig");

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
    /// The connection that `loadSchema` reads from. Set by `load`, so that it is null when the
    /// names were not loaded from a server: in the tests, and with `-A` until `rehash`.
    db: ?*Mysql.DB = null,
    /// The databases whose tables and routines are listed: the current one from `load`, and each
    /// other one that `loadSchema` was asked for, whether or not its queries worked.
    loaded: std.ArrayList([:0]u8) = .empty,
    /// True after a statement that may have changed the names, until they are loaded again.
    stale: bool = false,

    pub fn init(allocator: Allocator) Names {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Names) void {
        self.clear();
        self.databases.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.routines.deinit(self.allocator);
        self.loaded.deinit(self.allocator);
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
        freeWords(self.allocator, &self.loaded);
        self.db = null;
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

    /// The listed database that `name` names, ignoring ASCII case, or null when none does.
    pub fn findDatabase(self: *const Names, name: []const u8) ?[:0]const u8 {
        for (self.databases.items) |database| {
            if (std.ascii.eqlIgnoreCase(database, name)) return database;
        }
        return null;
    }

    /// Resolves a Vitess target such as `graph@replica` to its listed schema. An
    /// actual database with that full name takes precedence over a routing suffix.
    fn resolveCurrentDatabase(self: *Names) Allocator.Error!void {
        const current = self.database orelse return;
        if (self.findDatabase(current) != null) return;

        const at = std.mem.lastIndexOfScalar(u8, current, '@') orelse return;
        const target = current[at + 1 ..];
        for ([_][]const u8{ "primary", "replica", "rdonly", "master" }) |tablet_type| {
            if (!std.ascii.eqlIgnoreCase(target, tablet_type)) continue;
            const schema = self.findDatabase(current[0..at]) orelse return;
            try self.setDatabase(schema);
            return;
        }
    }

    /// True when the tables and routines of `schema` are listed, or were asked for.
    pub fn isLoaded(self: *const Names, schema: []const u8) bool {
        for (self.loaded.items) |name| {
            if (std.ascii.eqlIgnoreCase(name, schema)) return true;
        }
        return false;
    }

    /// Loads the tables and routines of `schema` the first time completion asks for them. Only a
    /// listed database is loaded, and only once: a failed query is not retried, so a lost
    /// connection costs one try per database. Does nothing when the names did not come from a
    /// server. Columns stay those of the current database, as in mysql.cc.
    pub fn loadSchema(self: *Names, schema: []const u8) Allocator.Error!void {
        const db = self.db orelse return;
        const name = self.findDatabase(schema) orelse return;
        if (self.isLoaded(name)) return;
        try self.markLoaded(name);
        try self.loadTablesAndRoutines(db, name);
    }

    /// Notes that a statement may have changed the names. Only names that came from a server are
    /// marked, so with `-A` nothing is loaded until `rehash`.
    pub fn markStale(self: *Names) void {
        if (self.db != null) self.stale = true;
    }

    /// Loads the names again when a statement has marked them stale. A failed query leaves its
    /// names out, as in `load`, and they are not retried until the next change.
    pub fn refreshIfStale(self: *Names) Allocator.Error!void {
        if (!self.stale) return;
        const db = self.db orelse return;
        _ = self.load(db) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn markLoaded(self: *Names, schema: []const u8) Allocator.Error!void {
        const owned = try self.allocator.dupeSentinel(u8, schema, 0);
        errdefer self.allocator.free(owned);
        try self.loaded.append(self.allocator, owned);
    }

    /// Adds the tables and routines of `schema`. The name goes in the queries as a hex literal,
    /// which needs no escaping in any sql_mode.
    fn loadTablesAndRoutines(self: *Names, db: *Mysql.DB, schema: []const u8) Allocator.Error!void {
        const literal = try schemaLiteral(self.allocator, schema);
        defer self.allocator.free(literal);

        const tables_sql = try std.fmt.allocPrint(self.allocator, "SELECT TABLE_NAME FROM information_schema.TABLES " ++
            "WHERE TABLE_SCHEMA = {s}", .{literal});
        defer self.allocator.free(tables_sql);
        if (try db.rowsCopy(self.allocator, tables_sql)) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |name| try self.addTable(schema, name);
            }
        }

        const routines_sql = try std.fmt.allocPrint(self.allocator, "SELECT ROUTINE_NAME FROM information_schema.ROUTINES " ++
            "WHERE ROUTINE_SCHEMA = {s}", .{literal});
        defer self.allocator.free(routines_sql);
        if (try db.rowsCopy(self.allocator, routines_sql)) |rows| {
            defer Mysql.freeRowsCopy(self.allocator, rows);
            for (rows) |row| {
                if (row[0]) |name| try self.addRoutine(schema, name);
            }
        }
    }

    /// Replaces the names with those of the server. Returns the number of tables in the
    /// current database, so the caller can decide whether to print a notice. A failed query
    /// leaves its names out, and the session carries on.
    pub fn load(self: *Names, db: *Mysql.DB) !u32 {
        self.clear();
        self.db = db;
        self.stale = false;

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

        try self.resolveCurrentDatabase();

        if (self.database) |current| {
            try self.markLoaded(current);
            try self.loadTablesAndRoutines(db, current);
            const literal = try schemaLiteral(self.allocator, current);
            defer self.allocator.free(literal);
            const columns_sql = try std.fmt.allocPrint(self.allocator, "SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS " ++
                "WHERE TABLE_SCHEMA = {s} ORDER BY TABLE_NAME, ORDINAL_POSITION", .{literal});
            defer self.allocator.free(columns_sql);
            if (try db.rowsCopy(self.allocator, columns_sql)) |rows| {
                defer Mysql.freeRowsCopy(self.allocator, rows);
                for (rows) |row| {
                    if (row[0]) |table| {
                        if (row[1]) |column| try self.addColumn(current, table, column);
                    }
                }
            }
        }

        // Only the current database's tables are listed now.
        return @intCast(self.tables.items.len);
    }
};

/// `schema` as an SQL expression: a utf8mb4 string from a hex literal, as in
/// `CONVERT(X'6170' USING utf8mb4)`.
fn schemaLiteral(allocator: Allocator, schema: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "CONVERT(X'{x}' USING utf8mb4)", .{schema});
}

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

/// True when `sql` may change the names that completion lists: its first word, after comments
/// and the opening of a version comment, is CREATE, DROP, ALTER or RENAME. Some of these, such
/// as CREATE USER, change no names, and only cost a reload.
pub fn changesNames(sql: []const u8, options: SqlLexer.Options) bool {
    var lexer = SqlLexer.Lexer.init(sql, options);
    while (lexer.next()) |token| switch (token.kind) {
        .whitespace, .comment, .version_comment_start => continue,
        .reserved_keyword, .keyword, .identifier => {
            const word = sql[token.start..token.end];
            for ([_][]const u8{ "CREATE", "DROP", "ALTER", "RENAME" }) |verb| {
                if (std.ascii.eqlIgnoreCase(word, verb)) return true;
            }
            return false;
        },
        else => return false,
    };
    return false;
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

test "Vitess tablet targets resolve to listed schemas for table and column completion" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();
    try names.addDatabase("graph");
    try names.addTable("graph", "people");
    try names.addColumn("graph", "people", "id");

    for ([_][]const u8{ "graph@replica", "graph@primary", "graph@rdonly", "graph@master" }) |target| {
        try names.setDatabase(target);
        try names.resolveCurrentDatabase();
        try std.testing.expectEqualStrings("graph", names.database.?);
        const table = names.findTable(null, "people").?;
        try std.testing.expectEqualStrings("id", table.columns.items[0]);
    }
}

test "schema resolution preserves real database names and unknown targets" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();
    try names.addDatabase("graph");
    try names.addDatabase("graph@replica");

    for ([_][]const u8{ "graph", "graph@replica", "graph@custom", "missing@primary", "@replica" }) |name| {
        try names.setDatabase(name);
        try names.resolveCurrentDatabase();
        try std.testing.expectEqualStrings(name, names.database.?);
    }
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

test "statements that create, drop, alter or rename something change the names" {
    try std.testing.expect(changesNames("CREATE TABLE another (id INT)", .{}));
    try std.testing.expect(changesNames("  drop view v", .{}));
    try std.testing.expect(changesNames("-- note\nALTER TABLE t ADD c INT", .{}));
    try std.testing.expect(changesNames("/* x */ rename table a to b", .{}));
    try std.testing.expect(changesNames("/*!50001 CREATE VIEW v AS SELECT 1 */", .{}));
    try std.testing.expect(!changesNames("SELECT 'CREATE'", .{}));
    try std.testing.expect(!changesNames("INSERT INTO created VALUES (1)", .{}));
    try std.testing.expect(!changesNames("", .{}));
}

test "only names from a server are marked stale" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();
    names.markStale();
    try std.testing.expect(!names.stale);
    try names.refreshIfStale();
}

test "prefix matching ignores case and needs the prefix at the start" {
    try std.testing.expect(matches("SELECT", "sel"));
    try std.testing.expect(matches("people.name", "PEOPLE."));
    try std.testing.expect(!matches("people", "ople"));
    try std.testing.expect(matches("anything", ""));
}

test "a schema goes in a query as a hex literal, whatever it holds" {
    const allocator = std.testing.allocator;
    const literal = try schemaLiteral(allocator, "a'b\\c");
    defer allocator.free(literal);
    try std.testing.expectEqualStrings("CONVERT(X'6127625c63' USING utf8mb4)", literal);
}

test "without a connection, loadSchema lists nothing and asks no server" {
    const allocator = std.testing.allocator;
    var names = Names.init(allocator);
    defer names.deinit();
    try names.addDatabase("app");
    try names.addDatabase("Other");
    try names.loadSchema("other");
    try std.testing.expect(!names.isLoaded("other"));
    try std.testing.expectEqualStrings("Other", names.findDatabase("OTHER").?);
    try std.testing.expect(names.findDatabase("missing") == null);
}
