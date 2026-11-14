//! Password sources. `fetch` turns an `Options.PasswordSource` into a password for one
//! connect. `Supplier` wraps it for `Mysql.DB`, which asks again on every connect, so
//! that a reconnect sees a fresh password.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = @import("options.zig");
const Keychain = @import("keychain.zig");

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

/// Why a password is needed. The auth command sees it as THYSQL_REASON.
pub const Reason = enum { connect, reconnect, complete };

/// The server a password is for. The auth command sees these as THYSQL_* variables.
pub const Target = struct {
    host: []const u8 = "",
    user: []const u8 = "",
    port: u32 = 0,
    database: []const u8 = "",
    socket: []const u8 = "",
    /// The -C connection name, or "" without -C.
    connection: []const u8 = "",
};

pub const FetchContext = struct {
    /// True when stdin is a terminal, so `.prompt` may ask for the password.
    interactive: bool,
    stderr: *std.Io.Writer,
    /// The environment of the thysql process. The auth command gets a copy, plus THYSQL_*.
    env: *const std.process.Environ.Map,
    target: Target = .{},
    reason: Reason = .connect,
    /// For `.command` only. The command is killed after this many milliseconds, and
    /// `error.Timeout` is returned. 0 means no limit, because an SSO helper can wait on a browser.
    timeout_ms: u64 = 0,
};

/// Output from the auth command past this many bytes is read and dropped.
const max_command_output = 64 * 1024;

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
        .command => |command| return runCommand(allocator, io, command, context),
        .keychain => |account| return fetchKeychain(allocator, io, account, context),
    }
}

/// Reads the keychain password for `account`, or for the connection name when `account` is "".
/// When it is not stored, the hint says how to store it. Interactive, a prompt follows the hint;
/// otherwise the connect fails with `error.KeychainNotFound`.
fn fetchKeychain(allocator: Allocator, io: std.Io, account: []const u8, context: FetchContext) !Secret {
    const from_connection = account.len == 0;
    const name = if (from_connection) context.target.connection else account;
    if (name.len == 0) {
        try report(context, "keychain needs -C or --keychain-account\n", .{});
        return error.KeychainNeedsAccount;
    }
    return Keychain.get(allocator, Keychain.pathFromEnv(context.env), name, context.stderr) catch |err| switch (err) {
        error.NotFound => {
            if (from_connection) {
                try report(context, "No keychain password for \"{s}\"; store one with: thysql keychain set {s}\n", .{ name, name });
            } else {
                try report(context, "No keychain password for \"{s}\"; store one with: thysql keychain set --account={s}\n", .{ name, name });
            }
            if (!context.interactive) {
                return error.KeychainNotFound;
            }
            return .{ .bytes = try readHiddenLine(allocator, io, context.stderr, "Enter password: "), .allocator = allocator };
        },
        else => return err,
    };
}

/// Runs `/bin/sh -c command` and returns the first line of its stdout. stderr is inherited,
/// so it can print progress. stdin is inherited only from a terminal, so it can prompt; when
/// SQL comes in on stdin the command gets /dev/null instead and cannot eat the script. A failure is reported on
/// `context.stderr` here. A timeout has no message, so the caller can report it.
fn runCommand(allocator: Allocator, io: std.Io, command: []const u8, context: FetchContext) !Secret {
    var env = try commandEnvironment(allocator, context);
    defer env.deinit();

    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .environ_map = &env,
        .stdin = if (context.interactive) .inherit else .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        try report(context, "auth command failed to start: {s}\n", .{@errorName(err)});
        return error.AuthCommandFailed;
    };

    const output = try allocator.alloc(u8, max_command_output);
    defer {
        std.crypto.secureZero(u8, output);
        allocator.free(output);
    }
    const captured = try readOutput(io, &child, output, context.timeout_ms);

    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) {
            try report(context, "auth command failed with exit status {}\n", .{code});
            return error.AuthCommandFailed;
        },
        .signal => |signal| {
            try report(context, "auth command killed by signal {d}\n", .{@backingInt(signal)});
            return error.AuthCommandFailed;
        },
        .stopped, .unknown => {
            try report(context, "auth command failed\n", .{});
            return error.AuthCommandFailed;
        },
    }

    const line_end = std.mem.indexOfScalar(u8, output[0..captured], '\n') orelse captured;
    var line = output[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0) {
        try report(context, "auth command printed no password\n", .{});
        return error.AuthCommandNoPassword;
    }
    return .{ .bytes = try allocator.dupeSentinel(u8, line, 0), .allocator = allocator };
}

/// Prints an auth command error and flushes it, so it shows before the caller's next output.
fn report(context: FetchContext, comptime format: []const u8, args: anytype) !void {
    try context.stderr.print(format, args);
    try context.stderr.flush();
}

/// Copies stdout into `buffer` until EOF, and returns how many bytes were kept. With a
/// timeout, it polls, and when the time is up it kills the child and returns `error.Timeout`.
fn readOutput(io: std.Io, child: *std.process.Child, buffer: []u8, timeout_ms: u64) !usize {
    const stdout = child.stdout.?;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var kept: usize = 0;
    var scratch: [4096]u8 = undefined;
    while (true) {
        if (timeout_ms > 0) {
            const elapsed_ms: u64 = @intCast(@divTrunc(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds, 1_000_000));
            if (elapsed_ms >= timeout_ms) {
                child.kill(io);
                return error.Timeout;
            }
            const remaining: i32 = @intCast(@min(timeout_ms - elapsed_ms, std.math.maxInt(i32)));
            var fds = [_]std.posix.pollfd{.{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, remaining) == 0) {
                child.kill(io);
                return error.Timeout;
            }
        }
        const count = std.posix.read(stdout.handle, &scratch) catch break;
        if (count == 0) {
            break;
        }
        const take = @min(buffer.len - kept, count);
        @memcpy(buffer[kept..][0..take], scratch[0..take]);
        kept += take;
    }
    return kept;
}

/// The environment for the auth command: a copy of thysql's environment, plus THYSQL_*.
fn commandEnvironment(allocator: Allocator, context: FetchContext) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    var entries = context.env.iterator();
    while (entries.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    const target = context.target;
    const port = try std.fmt.allocPrint(allocator, "{d}", .{target.port});
    defer allocator.free(port);
    try env.put("THYSQL_HOST", target.host);
    try env.put("THYSQL_PORT", port);
    try env.put("THYSQL_USER", target.user);
    try env.put("THYSQL_DATABASE", target.database);
    try env.put("THYSQL_SOCKET", target.socket);
    try env.put("THYSQL_CONNECTION", target.connection);
    try env.put("THYSQL_REASON", @tagName(context.reason));
    return env;
}

/// Supplies the password for every connect, through `Mysql.PasswordProvider`. A
/// `.prompt` source asks once, in `prime`, and keeps the answer for reconnects. Every
/// other source is fetched again on each call.
pub const Supplier = struct {
    allocator: Allocator,
    io: std.Io,
    source: Options.PasswordSource,
    context: FetchContext,
    /// The -C connection name, or "" without -C. The auth command gets it as THYSQL_CONNECTION.
    connection: []const u8 = "",
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

    /// Returns a password for a connect to `target`, for `reason`.
    pub fn get(self: *Supplier, target: Target, reason: Reason) !Secret {
        if (self.source != .prompt) {
            var context = self.context;
            context.target = target;
            context.target.connection = self.connection;
            context.reason = reason;
            return fetch(self.allocator, self.io, self.source, context);
        }
        try self.prime();
        return self.prompted.?.dupe();
    }

    /// The `fetchFn` for `Mysql.PasswordProvider`, with `ctx` set to a `*Supplier`.
    pub fn fetchOpaque(ctx: *anyopaque, target: Target, reason: Reason) anyerror!Secret {
        const self: *Supplier = @ptrCast(@alignCast(ctx));
        return self.get(target, reason);
    }
};

/// Reads a password line for `thysql keychain set`. A terminal gets a hidden prompt on stderr.
/// Piped input is read as it is, and the prompt is not shown.
pub fn readPassword(allocator: Allocator, io: std.Io, stderr: *std.Io.Writer, prompt: []const u8, interactive: bool) ![:0]u8 {
    if (interactive) {
        return readHiddenLine(allocator, io, stderr, prompt);
    }
    return readStdinLine(allocator, io);
}

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

    return readStdinLine(allocator, io);
}

/// Reads one line from stdin, without its line ending. It stops at a newline or a carriage return.
fn readStdinLine(allocator: Allocator, io: std.Io) ![:0]u8 {
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

fn testEnv() std.process.Environ.Map {
    return std.process.Environ.Map.init(std.testing.allocator);
}

test "literal copies the value and deinit frees it" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const secret = try fetch(std.testing.allocator, std.testing.io, .{ .literal = "pw" }, .{ .interactive = false, .stderr = &stderr, .env = &env });
    defer secret.deinit();
    try std.testing.expectEqualStrings("pw", secret.bytes);
    try std.testing.expectEqual(@as(u8, 0), secret.bytes[secret.bytes.len]);
}

test "prompt without an interactive stdin needs a prompt, and never prints one" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    try std.testing.expectError(error.NeedsPrompt, fetch(std.testing.allocator, std.testing.io, .prompt, .{ .interactive = false, .stderr = &stderr, .env = &env }));
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "a supplier returns a copy of its literal on every call" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    var supplier: Supplier = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .source = .{ .literal = "again" },
        .context = .{ .interactive = false, .stderr = &stderr, .env = &env },
    };
    defer supplier.deinit();
    for (0..2) |_| {
        const secret = try Supplier.fetchOpaque(&supplier, .{}, .connect);
        defer secret.deinit();
        try std.testing.expectEqualStrings("again", secret.bytes);
    }
}

test "auth command prints the password on its first line, without the line ending" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    const crlf = try fetch(std.testing.allocator, std.testing.io, .{ .command = "printf 'pw\\r\\nignored\\n'" }, context);
    defer crlf.deinit();
    try std.testing.expectEqualStrings("pw", crlf.bytes);
    const bare = try fetch(std.testing.allocator, std.testing.io, .{ .command = "printf 'no-newline'" }, context);
    defer bare.deinit();
    try std.testing.expectEqualStrings("no-newline", bare.bytes);
}

test "auth command sees the target and the reason as THYSQL_* variables" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    var supplier: Supplier = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .source = .{ .command = "printf '%s|%s|%s|%s|%s|%s|%s' \"$THYSQL_REASON\" \"$THYSQL_HOST\" \"$THYSQL_PORT\" \"$THYSQL_USER\" \"$THYSQL_DATABASE\" \"$THYSQL_SOCKET\" \"$THYSQL_CONNECTION\"" },
        .context = .{ .interactive = false, .stderr = &stderr, .env = &env },
        .connection = "main/ro",
    };
    defer supplier.deinit();
    const secret = try Supplier.fetchOpaque(&supplier, .{ .host = "db.example", .user = "app", .port = 3307, .database = "shop", .socket = "" }, .reconnect);
    defer secret.deinit();
    try std.testing.expectEqualStrings("reconnect|db.example|3307|app|shop||main/ro", secret.bytes);
}

test "auth command failures are reported on stderr, and an empty password is an error" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    try std.testing.expectError(error.AuthCommandFailed, fetch(std.testing.allocator, std.testing.io, .{ .command = "exit 3" }, context));
    try std.testing.expectError(error.AuthCommandNoPassword, fetch(std.testing.allocator, std.testing.io, .{ .command = "true" }, context));
    try std.testing.expectError(error.AuthCommandNoPassword, fetch(std.testing.allocator, std.testing.io, .{ .command = "printf '\\n'" }, context));
    const printed = stderr.buffered();
    try std.testing.expect(std.mem.indexOf(u8, printed, "auth command failed with exit status 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "auth command printed no password\n") != null);
}

test "keychain without an account or -C says what to add, and does not reach the keychain" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    try std.testing.expectError(error.KeychainNeedsAccount, fetch(std.testing.allocator, std.testing.io, .{ .keychain = "" }, context));
    try std.testing.expectEqualStrings("keychain needs -C or --keychain-account\n", stderr.buffered());
}

test "auth command that runs too long is killed at the timeout" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env, .timeout_ms = 100 };
    try std.testing.expectError(error.Timeout, fetch(std.testing.allocator, std.testing.io, .{ .command = "exec sleep 10" }, context));
}
