//! `thysql keychain set|delete|status <connection>`: keeps the keychain password of a
//! connection. `<connection>` resolves as -C does, so `main` can mean `main/ro`. Use
//! `--account=name` for an account with no connection file. The password is never printed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Connections = @import("connections.zig");
const Keychain = @import("keychain.zig");
const Password = @import("password.zig");

const account_prefix = "--account=";
const usage =
    \\usage: thysql keychain set|delete|status <connection>
    \\       thysql keychain set|delete|status --account=<name>
    \\
;

/// Runs one keychain subcommand. `args` is the whole argv, with `keychain` at args[1].
pub fn run(
    allocator: Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    args: []const []const u8,
    env: *const std.process.Environ.Map,
) !u8 {
    if (args.len != 4) {
        try stderr.writeAll(usage);
        return 1;
    }
    const verb = args[2];
    if (!std.mem.eql(u8, verb, "set") and !std.mem.eql(u8, verb, "delete") and !std.mem.eql(u8, verb, "status")) {
        try stderr.writeAll(usage);
        return 1;
    }

    var resolved: ?Connections.Resolved = null;
    defer if (resolved) |*owned| owned.deinit();
    const account = if (std.mem.startsWith(u8, args[3], account_prefix)) blk: {
        const name = args[3][account_prefix.len..];
        if (name.len == 0) {
            try stderr.writeAll(usage);
            return 1;
        }
        break :blk name;
    } else blk: {
        resolved = Connections.resolve(allocator, io, env, stderr, args[3]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.ConnectionFailed => return 1,
        };
        break :blk resolved.?.name;
    };

    const keychain_path = Keychain.pathFromEnv(env);
    if (std.mem.eql(u8, verb, "set")) {
        return set(allocator, io, stdout, stderr, keychain_path, account);
    }
    if (std.mem.eql(u8, verb, "delete")) {
        return delete(stdout, stderr, keychain_path, account);
    }
    return status(allocator, stdout, stderr, keychain_path, account);
}

/// Stores a password read from a prompt on a terminal, or one line from piped stdin.
fn set(allocator: Allocator, io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer, keychain_path: ?[]const u8, account: []const u8) !u8 {
    const interactive = try std.Io.File.stdin().isTty(io);
    const prompt = try std.fmt.allocPrint(allocator, "Password for {s}: ", .{account});
    defer allocator.free(prompt);
    const password = try Password.readPassword(allocator, io, stderr, prompt, interactive);
    defer {
        std.crypto.secureZero(u8, password);
        allocator.free(password);
    }
    if (password.len == 0) {
        try stderr.print("No password given; nothing was stored.\n", .{});
        return 1;
    }

    Keychain.set(keychain_path, account, password, stderr) catch |err| switch (err) {
        error.KeychainFailed, error.Unsupported => return 1,
        else => return err,
    };
    try stdout.print("Saved password for \"{s}\" in the keychain.\n", .{account});
    return 0;
}

fn delete(stdout: *std.Io.Writer, stderr: *std.Io.Writer, keychain_path: ?[]const u8, account: []const u8) !u8 {
    Keychain.delete(keychain_path, account, stderr) catch |err| switch (err) {
        error.NotFound => {
            try stderr.print("no keychain password for \"{s}\"\n", .{account});
            return 1;
        },
        error.KeychainFailed, error.Unsupported => return 1,
        else => return err,
    };
    try stdout.print("Deleted password for \"{s}\" from the keychain.\n", .{account});
    return 0;
}

fn status(allocator: Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer, keychain_path: ?[]const u8, account: []const u8) !u8 {
    const secret = Keychain.get(allocator, keychain_path, account, stderr) catch |err| switch (err) {
        error.NotFound => {
            try stdout.writeAll("not stored\n");
            return 1;
        },
        error.KeychainFailed, error.Unsupported => return 1,
        else => return err,
    };
    secret.deinit();
    try stdout.writeAll("stored\n");
    return 0;
}

test "keychain subcommands print usage for a missing or unknown verb" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const short = [_][]const u8{ "thysql", "keychain" };
    try std.testing.expectEqual(@as(u8, 1), try run(std.testing.allocator, std.testing.io, &stdout, &stderr, &short, &env));
    const unknown = [_][]const u8{ "thysql", "keychain", "rotate", "main" };
    try std.testing.expectEqual(@as(u8, 1), try run(std.testing.allocator, std.testing.io, &stdout, &stderr, &unknown, &env));
    try std.testing.expectEqualStrings(usage ++ usage, stderr.buffered());
    try std.testing.expectEqualStrings("", stdout.buffered());
}

test "an empty --account= is a usage error" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const empty = [_][]const u8{ "thysql", "keychain", "status", "--account=" };
    try std.testing.expectEqual(@as(u8, 1), try run(std.testing.allocator, std.testing.io, &stdout, &stderr, &empty, &env));
    try std.testing.expectEqualStrings(usage, stderr.buffered());
}
