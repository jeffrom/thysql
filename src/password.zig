//! Password sources. `fetch` turns an `Options.PasswordSource` into a password for one
//! connect. `Supplier` wraps it for `Mysql.DB`, which asks again on every connect, so
//! that a reconnect sees a fresh password.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = @import("options.zig");

/// A password for one connect. It is NUL-terminated for the C library. `deinit` zeroes
/// the bytes before freeing them.
pub const Secret = struct {
    bytes: [:0]u8,
    allocator: Allocator,

    pub fn deinit(self: Secret) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
    }

    pub fn dupe(self: Secret) !Secret {
        return .{ .bytes = try self.allocator.dupeSentinel(u8, self.bytes, 0), .allocator = self.allocator };
    }
};

pub const FetchContext = struct {
    /// True when stdin is a terminal, so `.prompt` may ask for the password.
    interactive: bool,
    stderr: *std.Io.Writer,
};

/// Returns the password for `source`. The caller owns the result and calls `deinit`.
/// `.prompt` without an interactive stdin returns `error.NeedsPrompt`.
pub fn fetch(allocator: Allocator, io: std.Io, source: Options.PasswordSource, context: FetchContext) !Secret {
    switch (source) {
        .literal => |value| return .{ .bytes = try allocator.dupeSentinel(u8, value, 0), .allocator = allocator },
        .prompt => {
            if (!context.interactive) {
                return error.NeedsPrompt;
            }
            return .{ .bytes = try readHiddenLine(allocator, io, context.stderr, "Enter password: "), .allocator = allocator };
        },
        // Later steps: the auth command and the keychain.
        .command, .keychain => return error.Unsupported,
    }
}

/// Supplies the password for every connect, through `Mysql.PasswordProvider`. A
/// `.prompt` source asks once, in `prime`, and keeps the answer for reconnects. Every
/// other source is fetched again on each call.
pub const Supplier = struct {
    allocator: Allocator,
    io: std.Io,
    source: Options.PasswordSource,
    context: FetchContext,
    prompted: ?Secret = null,

    pub fn deinit(self: *Supplier) void {
        if (self.prompted) |secret| {
            secret.deinit();
        }
        self.prompted = null;
    }

    /// Asks for a `.prompt` password now, so the prompt comes before the first connect.
    /// Other sources do nothing here.
    pub fn prime(self: *Supplier) !void {
        if (self.source != .prompt or self.prompted != null) {
            return;
        }
        self.prompted = try fetch(self.allocator, self.io, self.source, self.context);
    }

    pub fn get(self: *Supplier) !Secret {
        if (self.source != .prompt) {
            return fetch(self.allocator, self.io, self.source, self.context);
        }
        try self.prime();
        return self.prompted.?.dupe();
    }

    /// The `fetchFn` for `Mysql.PasswordProvider`, with `ctx` set to a `*Supplier`.
    pub fn fetchOpaque(ctx: *anyopaque) anyerror!Secret {
        const self: *Supplier = @ptrCast(@alignCast(ctx));
        return self.get();
    }
};

/// Reads a line from stdin with echo off. The prompt goes to stderr.
fn readHiddenLine(allocator: Allocator, io: std.Io, stderr: *std.Io.Writer, prompt: []const u8) ![:0]u8 {
    try stderr.print("{s}", .{prompt});
    try stderr.flush();

    const stdin_fd = std.posix.STDIN_FILENO;
    const original_term = try std.posix.tcgetattr(stdin_fd);
    var hidden_term = original_term;
    hidden_term.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin_fd, .NOW, hidden_term);
    defer std.posix.tcsetattr(stdin_fd, .NOW, original_term) catch {};
    defer stderr.print("\n", .{}) catch {};

    var stdin_buffer: [128]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const read = try stdin_reader.interface.readSliceShort(&byte);
        if (read == 0 or byte[0] == '\n') {
            break;
        }
        if (byte[0] == '\r') {
            break;
        }
        try line.append(allocator, byte[0]);
    }

    return line.toOwnedSliceSentinel(allocator, 0);
}

test "literal copies the value and deinit frees it" {
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const secret = try fetch(std.testing.allocator, std.testing.io, .{ .literal = "pw" }, .{ .interactive = false, .stderr = &stderr });
    defer secret.deinit();
    try std.testing.expectEqualStrings("pw", secret.bytes);
    try std.testing.expectEqual(@as(u8, 0), secret.bytes[secret.bytes.len]);
}

test "prompt without an interactive stdin needs a prompt, and never prints one" {
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    try std.testing.expectError(error.NeedsPrompt, fetch(std.testing.allocator, std.testing.io, .prompt, .{ .interactive = false, .stderr = &stderr }));
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "a supplier returns a copy of its literal on every call" {
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    var supplier: Supplier = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .source = .{ .literal = "again" },
        .context = .{ .interactive = false, .stderr = &stderr },
    };
    defer supplier.deinit();
    for (0..2) |_| {
        const secret = try Supplier.fetchOpaque(&supplier);
        defer secret.deinit();
        try std.testing.expectEqualStrings("again", secret.bytes);
    }
}
