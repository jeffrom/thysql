const std = @import("std");
const Allocator = std.mem.Allocator;

const Connections = @import("connections.zig");
const Mysql = @import("mysql.zig");
const OptionFile = @import("option_file.zig");
const Options = @import("options.zig");
const Password = @import("password.zig");

const CompletionRequest = struct {
    database_prefix: []const u8,
    connection_args: std.ArrayList([]const u8),

    fn deinit(self: *CompletionRequest, allocator: Allocator) void {
        self.connection_args.deinit(allocator);
    }
};

fn parseRequest(allocator: Allocator, args: []const []const u8) !CompletionRequest {
    var request = CompletionRequest{
        .database_prefix = "",
        .connection_args = .empty,
    };
    errdefer request.deinit(allocator);

    if (args.len > 0) {
        try request.connection_args.append(allocator, args[0]);
    }

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--database")) {
            if (i + 1 < args.len) {
                request.database_prefix = args[i + 1];
                i += 1;
            } else {
                request.database_prefix = "";
            }
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-D")) {
            request.database_prefix = arg[2..];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--database=")) {
            request.database_prefix = arg["--database=".len..];
            continue;
        }

        if (std.mem.startsWith(u8, arg, "(-D)")) {
            request.database_prefix = arg["(-D)".len..];
            continue;
        }

        if (i == args.len - 1 and request.database_prefix.len == 0 and !std.mem.startsWith(u8, arg, "-")) {
            request.database_prefix = arg;
            continue;
        }

        try request.connection_args.append(allocator, arg);
    }

    return request;
}

pub fn run(
    allocator: Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    args: []const []const u8,
    env: *const std.process.Environ.Map,
) !u8 {
    var request = try parseRequest(allocator, args);
    defer request.deinit(allocator);

    // It connects like the REPL, so it reads the same option files.
    var loaded = OptionFile.load(allocator, io, env, request.connection_args.items, stderr) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.OptionFileFailed => return 1,
    };
    defer loaded.deinit();
    var selection = Connections.select(allocator, io, env, stderr, request.connection_args.items, loaded.next, loaded.settings) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ConnectionFailed => return 1,
    };
    defer selection.deinit();
    if (loaded.print_defaults) {
        try OptionFile.renderPrintDefaults(stdout, args[0], selection.settings, request.connection_args.items[loaded.next..]);
        return 0;
    }

    var options = Options.parseWithSettings(allocator, request.connection_args.items, loaded.next, env, selection.settings) catch |err| {
        try Options.renderError(stderr, err);
        return 1;
    };
    defer options.deinit(allocator);
    options.connection = selection.name();

    if (options.password_source == .prompt) {
        try stderr.print("Cannot prompt for a password during completion; use MYSQL_PWD.\n", .{});
        return 1;
    }

    var password_supplier: Password.Supplier = .{
        .allocator = allocator,
        .io = io,
        .source = options.password_source,
        .context = .{ .interactive = false, .stderr = stderr, .env = env },
        .connection = options.connection orelse "",
    };
    defer password_supplier.deinit();

    var db = try Mysql.DB.init(allocator, .{
        .host = options.host,
        .user = options.user,
        .password_provider = .{ .ctx = &password_supplier, .fetchFn = Password.Supplier.fetchOpaque },
        .database = "",
        .port = options.port,
        .socket = options.socket,
        .protocol = options.protocol,
        .tls = options.tls,
        .connect_timeout = options.connect_timeout,
    });
    defer db.close();

    db.renderDatabaseCompletions(stdout, request.database_prefix) catch |err| {
        switch (err) {
            Mysql.DBError.ExecError, Mysql.DBError.StoreResultError => {
                try db.renderLastError(stderr);
                return 1;
            },
            else => return err,
        }
    };

    return 0;
}

test "completion request extracts database prefix and keeps connection args" {
    const args = [_][]const u8{ "thysql", "complete", "-h", "127.0.0.1", "-uroot", "-Dthy" };
    var request = try parseRequest(std.testing.allocator, &args);
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("thy", request.database_prefix);
    try std.testing.expectEqual(@as(usize, 4), request.connection_args.items.len);
    try std.testing.expectEqualStrings("thysql", request.connection_args.items[0]);
    try std.testing.expectEqualStrings("-h", request.connection_args.items[1]);
    try std.testing.expectEqualStrings("127.0.0.1", request.connection_args.items[2]);
    try std.testing.expectEqualStrings("-uroot", request.connection_args.items[3]);
}

test "completion request supports separated database prefix" {
    const args = [_][]const u8{ "thysql", "complete", "--database", "app" };
    var request = try parseRequest(std.testing.allocator, &args);
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", request.database_prefix);
    try std.testing.expectEqual(@as(usize, 1), request.connection_args.items.len);
    try std.testing.expectEqualStrings("thysql", request.connection_args.items[0]);
}
