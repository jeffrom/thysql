//! The macOS keychain, through the C shim in src/keychain/keychain.h. Items are generic
//! passwords in service `thysql`, one per connection name. Elsewhere every call fails
//! with `error.Unsupported` and says so on the writer it is given.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Password = @import("password.zig");

const c = if (builtin.os.tag == .macos) @import("keychain_c") else void;

/// The service name of every thysql item.
pub const service = "thysql";

/// The environment variable that names a keychain file, for tests. Empty or unset means the default search list.
pub const path_env = "THYSQL_KEYCHAIN";

pub const Error = error{ NotFound, KeychainFailed, Unsupported, OutOfMemory };

/// The keychain file from THYSQL_KEYCHAIN, or null for the default search list.
pub fn pathFromEnv(env: *const std.process.Environ.Map) ?[]const u8 {
    const value = env.get(path_env) orelse return null;
    return if (value.len == 0) null else value;
}

/// Returns the password stored for `account`. The caller calls `deinit` on the result.
pub fn get(allocator: Allocator, keychain_path: ?[]const u8, account: []const u8, stderr: *std.Io.Writer) Error!Password.Secret {
    if (comptime builtin.os.tag != .macos) {
        _ = .{ allocator, keychain_path, account };
        return unsupported(stderr);
    } else {
        return darwinGet(allocator, keychain_path, account, stderr);
    }
}

/// Stores `password` for `account`, replacing any password already stored there.
pub fn set(keychain_path: ?[]const u8, account: []const u8, password: []const u8, stderr: *std.Io.Writer) Error!void {
    if (comptime builtin.os.tag != .macos) {
        _ = .{ keychain_path, account, password };
        return unsupported(stderr);
    } else {
        return darwinSet(keychain_path, account, password, stderr);
    }
}

/// Removes the password stored for `account`. Returns `error.NotFound` when there is none.
pub fn delete(keychain_path: ?[]const u8, account: []const u8, stderr: *std.Io.Writer) Error!void {
    if (comptime builtin.os.tag != .macos) {
        _ = .{ keychain_path, account };
        return unsupported(stderr);
    } else {
        return darwinDelete(keychain_path, account, stderr);
    }
}

fn unsupported(stderr: *std.Io.Writer) Error {
    stderr.print("the keychain is only supported on macOS\n", .{}) catch {};
    return error.Unsupported;
}

/// Turns a non-zero shim status into `KeychainFailed`, after printing its message.
fn failed(stderr: *std.Io.Writer, status: c_int) Error {
    if (comptime builtin.os.tag == .macos) {
        if (c.thysql_keychain_error_message(status)) |text| {
            defer std.c.free(text);
            stderr.print("keychain: {s}\n", .{std.mem.span(text)}) catch {};
            return error.KeychainFailed;
        }
    }
    stderr.print("keychain: error {d}\n", .{status}) catch {};
    return error.KeychainFailed;
}

/// A keychain path for the C shim: a sentinel-terminated copy, or null. The caller frees it.
fn cPath(allocator: Allocator, keychain_path: ?[]const u8) Allocator.Error!?[:0]u8 {
    const path = keychain_path orelse return null;
    return try allocator.dupeSentinel(u8, path, 0);
}

fn darwinGet(allocator: Allocator, keychain_path: ?[]const u8, account: []const u8, stderr: *std.Io.Writer) Error!Password.Secret {
    const path = try cPath(allocator, keychain_path);
    defer if (path) |owned| allocator.free(owned);
    const account_z = try allocator.dupeSentinel(u8, account, 0);
    defer allocator.free(account_z);

    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    const status = c.thysql_keychain_get(if (path) |owned| owned.ptr else null, service, account_z.ptr, &out, &out_len);
    if (status == 1) return error.NotFound;
    if (status != 0) return failed(stderr, status);

    // Copy the password into Zig memory, then zero and free the shim's copy.
    defer c.thysql_keychain_free(out, out_len);
    const bytes = try allocator.dupeSentinel(u8, out.?[0..out_len], 0);
    return .{ .bytes = bytes, .allocator = allocator };
}

fn darwinSet(keychain_path: ?[]const u8, account: []const u8, password: []const u8, stderr: *std.Io.Writer) Error!void {
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fixed.allocator();
    const path = try cPath(allocator, keychain_path);
    const account_z = try allocator.dupeSentinel(u8, account, 0);

    const status = c.thysql_keychain_set(if (path) |owned| owned.ptr else null, service, account_z.ptr, password.ptr, password.len);
    if (status != 0) return failed(stderr, status);
}

fn darwinDelete(keychain_path: ?[]const u8, account: []const u8, stderr: *std.Io.Writer) Error!void {
    var buffer: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fixed.allocator();
    const path = try cPath(allocator, keychain_path);
    const account_z = try allocator.dupeSentinel(u8, account, 0);

    const status = c.thysql_keychain_delete(if (path) |owned| owned.ptr else null, service, account_z.ptr);
    if (status == 1) return error.NotFound;
    if (status != 0) return failed(stderr, status);
}

test "THYSQL_KEYCHAIN is the keychain path, and empty or unset means the default list" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(pathFromEnv(&env) == null);
    try env.put(path_env, "");
    try std.testing.expect(pathFromEnv(&env) == null);
    try env.put(path_env, "/tmp/test.keychain-db");
    try std.testing.expectEqualStrings("/tmp/test.keychain-db", pathFromEnv(&env).?);
}

test "off macOS every keychain call is unsupported, and says so" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.Unsupported, get(std.testing.allocator, null, "main/ro", &stderr));
    try std.testing.expectError(error.Unsupported, set(null, "main/ro", "pw", &stderr));
    try std.testing.expectError(error.Unsupported, delete(null, "main/ro", &stderr));
    try std.testing.expectEqualStrings(
        "the keychain is only supported on macOS\nthe keychain is only supported on macOS\nthe keychain is only supported on macOS\n",
        stderr.buffered(),
    );
}
