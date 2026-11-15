//! Password sources. `fetch` turns an `Options.PasswordSource` into a password for one
//! connect. `Supplier` wraps it for `Mysql.DB`, which asks again on every connect, so
//! that a reconnect sees a fresh password.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Options = @import("options.zig");
const OptionFile = @import("option_file.zig");
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
    /// For `.command` only. The command's stderr goes to /dev/null instead of the terminal.
    /// `thysql complete` sets this, so a helper cannot print during tab completion.
    discard_command_stderr: bool = false,
};

/// Output from the auth command past this many bytes is read and dropped.
const max_command_output = 64 * 1024;

/// Room for the parsed JSON of an auth command's output. It is zeroed afterwards.
const json_buffer_size = 1024 * 1024;

/// Connection settings that the auth command's JSON set. A null field was not set by the JSON.
/// Field names match `Options.ConnectField`, and the password is in `AuthOutput`.
pub const Settings = struct {
    host: ?[]const u8 = null,
    port: ?u32 = null,
    user: ?[]const u8 = null,
    database: ?[]const u8 = null,
    socket: ?[]const u8 = null,
    protocol: ?Options.Protocol = null,
    ssl: ?bool = null,
    ssl_ca: ?[]const u8 = null,
    ssl_capath: ?[]const u8 = null,
    ssl_cert: ?[]const u8 = null,
    ssl_key: ?[]const u8 = null,
    ssl_cipher: ?[]const u8 = null,
    ssl_crl: ?[]const u8 = null,
    ssl_crlpath: ?[]const u8 = null,
    tls_version: ?[]const u8 = null,
    ssl_verify_server_cert: ?bool = null,
};

/// What an auth command printed: the password, and any settings from a JSON object.
pub const AuthOutput = struct {
    password: Secret,
    settings: Settings = .{},
    /// Owns the strings in `settings`.
    arena: std.heap.ArenaAllocator,
    /// Set when the output started with "{" but was not valid JSON. The output was then used as
    /// the password line, so a failed connect can say why.
    json_error: ?anyerror = null,

    pub fn deinit(self: *AuthOutput) void {
        self.password.deinit();
        self.arena.deinit();
    }
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
        .command => |command| {
            // Until connect applies the settings, only the password is used.
            var output = try runCommand(allocator, io, command, context);
            defer output.arena.deinit();
            return output.password;
        },
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

/// Runs `/bin/sh -c command` and parses its stdout with `parseAuthOutput`. stderr is inherited,
/// so it can print progress. stdin is inherited only from a terminal, so it can prompt; when
/// SQL comes in on stdin the command gets /dev/null instead and cannot eat the script. A failure is reported on
/// `context.stderr` here. A timeout has no message, so the caller can report it.
fn runCommand(allocator: Allocator, io: std.Io, command: []const u8, context: FetchContext) !AuthOutput {
    var env = try commandEnvironment(allocator, context);
    defer env.deinit();

    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .environ_map = &env,
        .stdin = if (context.interactive) .inherit else .ignore,
        .stdout = .pipe,
        .stderr = if (context.discard_command_stderr) .ignore else .inherit,
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

    // Output that filled the buffer may have been cut off, which matters for JSON.
    return parseAuthOutput(allocator, output[0..captured], captured == output.len, context);
}

/// Parses what an auth command printed. Once whitespace is trimmed from both ends, output that
/// starts with "{" is a JSON object of settings. Anything else, and JSON that does not parse, is
/// a password on the first line. `truncated` says the output was cut at `max_command_output`.
/// Problems are reported on `context.stderr`, and the error returned says which kind they were.
pub fn parseAuthOutput(allocator: Allocator, bytes: []const u8, truncated: bool, context: FetchContext) !AuthOutput {
    const text = std.mem.trim(u8, bytes, " \t\r\n");
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    var json_error: ?anyerror = null;
    if (text.len > 0 and text[0] == '{') {
        // The parse tree holds the password and other secrets, so it lives in a buffer that is zeroed afterwards.
        const json_buffer = try allocator.alloc(u8, json_buffer_size);
        defer {
            std.crypto.secureZero(u8, json_buffer);
            allocator.free(json_buffer);
        }
        var fixed: std.heap.FixedBufferAllocator = .init(json_buffer);
        if (std.json.parseFromSliceLeaky(std.json.Value, fixed.allocator(), text, .{})) |value| {
            const parsed = try settingsFromObject(allocator, arena.allocator(), value.object, context);
            return .{ .password = parsed.password, .settings = parsed.settings, .arena = arena };
        } else |err| switch (err) {
            error.OutOfMemory => return fail(context, error.AuthCommandFailed, "auth command: the JSON settings are too large\n", .{}),
            else => {
                if (truncated) {
                    return fail(context, error.AuthCommandFailed, "auth command: output is larger than 64 KiB, so its JSON is cut off\n", .{});
                }
                json_error = err;
            },
        }
    }

    // A password line is the first line exactly as printed, so spaces in a password are kept.
    // Only the JSON check above trims.
    const line_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    var line = bytes[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0) {
        return fail(context, error.AuthCommandNoPassword, "auth command printed no password\n", .{});
    }
    return .{
        .password = .{ .bytes = try allocator.dupeSentinel(u8, line, 0), .allocator = allocator },
        .arena = arena,
        .json_error = json_error,
    };
}

/// The password and settings read from the JSON object. Strings in `settings` are copied into the arena.
const Parsed = struct {
    password: Secret,
    settings: Settings,
};

/// Reads the settings object. Keys are matched like option names, so "-" and "_" are alike.
/// A key that starts with "_" is ignored, and so is any value under it. Other unknown keys fail.
fn settingsFromObject(allocator: Allocator, arena: Allocator, object: std.json.ObjectMap, context: FetchContext) !Parsed {
    var settings: Settings = .{};
    var password: []const u8 = "";
    var entries = object.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len > 0 and name[0] == '_') {
            continue;
        }
        const key = settingKey(name) orelse {
            return fail(context, error.AuthCommandFailed, "auth command: unknown key \"{s}\"\n", .{name});
        };
        const value = entry.value_ptr.*;
        switch (key) {
            .password => password = (try stringSetting(value, name, context)) orelse "",
            .host => settings.host = try copySetting(arena, value, name, context),
            .port => settings.port = try portSetting(value, name, context),
            .user => settings.user = try copySetting(arena, value, name, context),
            .database => settings.database = try copySetting(arena, value, name, context),
            .socket => settings.socket = try copySetting(arena, value, name, context),
            .protocol => settings.protocol = try protocolSetting(value, name, context),
            .ssl => settings.ssl = try boolSetting(value, name, context),
            .ssl_ca => settings.ssl_ca = try copySetting(arena, value, name, context),
            .ssl_capath => settings.ssl_capath = try copySetting(arena, value, name, context),
            .ssl_cert => settings.ssl_cert = try copySetting(arena, value, name, context),
            .ssl_key => settings.ssl_key = try copySetting(arena, value, name, context),
            .ssl_cipher => settings.ssl_cipher = try copySetting(arena, value, name, context),
            .ssl_crl => settings.ssl_crl = try copySetting(arena, value, name, context),
            .ssl_crlpath => settings.ssl_crlpath = try copySetting(arena, value, name, context),
            .tls_version => settings.tls_version = try copySetting(arena, value, name, context),
            .ssl_verify_server_cert => settings.ssl_verify_server_cert = try boolSetting(value, name, context),
        }
    }
    return .{
        .password = .{ .bytes = try allocator.dupeSentinel(u8, password, 0), .allocator = allocator },
        .settings = settings,
    };
}

/// The connection field a JSON key sets, or null for an unknown key.
fn settingKey(name: []const u8) ?Options.ConnectField {
    for (std.enums.values(Options.ConnectField)) |field| {
        if (OptionFile.sameName(@tagName(field), name)) {
            return field;
        }
    }
    return null;
}

/// A string value. `null` means the key is not set, and any other type is an error.
fn stringSetting(value: std.json.Value, name: []const u8, context: FetchContext) !?[]const u8 {
    switch (value) {
        .null => return null,
        .string => |text| return text,
        else => return fail(context, error.AuthCommandFailed, "auth command: \"{s}\" must be a string\n", .{name}),
    }
}

/// A string value, copied into `arena` because the parse buffer is zeroed.
fn copySetting(arena: Allocator, value: std.json.Value, name: []const u8, context: FetchContext) !?[]const u8 {
    const text = (try stringSetting(value, name, context)) orelse return null;
    return try arena.dupe(u8, text);
}

/// A port as a number or a string of digits.
fn portSetting(value: std.json.Value, name: []const u8, context: FetchContext) !?u32 {
    switch (value) {
        .null => return null,
        .integer => |number| return std.math.cast(u32, number) orelse
            return fail(context, error.AuthCommandFailed, "auth command: invalid port {d}\n", .{number}),
        .string => |text| return std.fmt.parseUnsigned(u32, text, 10) catch
            return fail(context, error.AuthCommandFailed, "auth command: invalid port \"{s}\"\n", .{text}),
        else => return fail(context, error.AuthCommandFailed, "auth command: \"{s}\" must be a number or string\n", .{name}),
    }
}

/// A protocol name, as --protocol takes it.
fn protocolSetting(value: std.json.Value, name: []const u8, context: FetchContext) !?Options.Protocol {
    switch (value) {
        .null => return null,
        .string => |text| return Options.protocolValue(text) catch
            return fail(context, error.AuthCommandFailed, "auth command: invalid protocol \"{s}\"\n", .{text}),
        else => return fail(context, error.AuthCommandFailed, "auth command: \"{s}\" must be a string\n", .{name}),
    }
}

/// A boolean, as a JSON bool or a word that --ssl takes ("1", "on", "yes", ...).
fn boolSetting(value: std.json.Value, name: []const u8, context: FetchContext) !?bool {
    switch (value) {
        .null => return null,
        .bool => |flag| return flag,
        .string => |text| return Options.boolValue(text) catch
            return fail(context, error.AuthCommandFailed, "auth command: \"{s}\" must be true or false\n", .{name}),
        else => return fail(context, error.AuthCommandFailed, "auth command: \"{s}\" must be true or false\n", .{name}),
    }
}

/// Prints an auth command output error, and returns `err` for the caller to return. The message
/// reaches the user even though the connect is failing anyway.
fn fail(context: FetchContext, err: AuthError, comptime format: []const u8, args: anytype) AuthError {
    report(context, format, args) catch {};
    return err;
}

/// The errors `parseAuthOutput` returns. Each one has already been reported.
const AuthError = error{ AuthCommandFailed, AuthCommandNoPassword };

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
    /// When set, every fetch reports this reason instead of the one the caller passes. Completion uses `.complete`.
    fixed_reason: ?Reason = null,
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
            context.reason = self.fixed_reason orelse reason;
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

test "auth output: a plain line is the password, without the line ending, and sets nothing" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try parseAuthOutput(std.testing.allocator, "pw\r\nignored\n", false, context);
    defer output.deinit();
    try std.testing.expectEqualStrings("pw", output.password.bytes);
    try std.testing.expectEqual(@as(?bool, null), output.settings.ssl);
    try std.testing.expectEqual(@as(?[]const u8, null), output.settings.host);
    try std.testing.expect(output.json_error == null);
}

test "auth output: a password line keeps its spaces" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try parseAuthOutput(std.testing.allocator, " pw \n", false, context);
    defer output.deinit();
    try std.testing.expectEqualStrings(" pw ", output.password.bytes);
    try std.testing.expectError(error.AuthCommandNoPassword, parseAuthOutput(std.testing.allocator, "\npw\n", false, context));
}

test "auth output: a line that starts with { but is not JSON is the password, and records why" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try parseAuthOutput(std.testing.allocator, "{abc\n", false, context);
    defer output.deinit();
    try std.testing.expectEqualStrings("{abc", output.password.bytes);
    try std.testing.expect(output.json_error != null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "auth output: JSON with every key sets every connection field" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    const text =
        \\ {"host":"db","port":3307,"user":"app","password":"p\"w@",
        \\  "database":"shop","socket":"/tmp/s.sock","protocol":"socket","ssl":true,
        \\  "ssl-ca":"ca.pem","ssl_capath":"/capath","ssl-cert":"c.pem","ssl-key":"k.pem",
        \\  "ssl-cipher":"ECDHE","ssl-crl":"crl.pem","ssl-crlpath":"/crl","tls-version":"TLSv1.3",
        \\  "ssl-verify-server-cert":false} 
        \\
    ;
    var output = try parseAuthOutput(std.testing.allocator, text, false, context);
    defer output.deinit();
    const settings = output.settings;
    try std.testing.expectEqualStrings("p\"w@", output.password.bytes);
    try std.testing.expectEqualStrings("db", settings.host.?);
    try std.testing.expectEqual(@as(?u32, 3307), settings.port);
    try std.testing.expectEqualStrings("app", settings.user.?);
    try std.testing.expectEqualStrings("shop", settings.database.?);
    try std.testing.expectEqualStrings("/tmp/s.sock", settings.socket.?);
    try std.testing.expectEqual(@as(?Options.Protocol, .socket), settings.protocol);
    try std.testing.expectEqual(@as(?bool, true), settings.ssl);
    try std.testing.expectEqualStrings("ca.pem", settings.ssl_ca.?);
    try std.testing.expectEqualStrings("/capath", settings.ssl_capath.?);
    try std.testing.expectEqualStrings("c.pem", settings.ssl_cert.?);
    try std.testing.expectEqualStrings("k.pem", settings.ssl_key.?);
    try std.testing.expectEqualStrings("ECDHE", settings.ssl_cipher.?);
    try std.testing.expectEqualStrings("crl.pem", settings.ssl_crl.?);
    try std.testing.expectEqualStrings("/crl", settings.ssl_crlpath.?);
    try std.testing.expectEqualStrings("TLSv1.3", settings.tls_version.?);
    try std.testing.expectEqual(@as(?bool, false), settings.ssl_verify_server_cert);
}

test "auth output: port takes a number or a string of digits, and rejects the rest" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var by_number = try parseAuthOutput(std.testing.allocator, "{\"port\":3306}", false, context);
    defer by_number.deinit();
    try std.testing.expectEqual(@as(?u32, 3306), by_number.settings.port);
    var by_string = try parseAuthOutput(std.testing.allocator, "{\"port\":\"3308\"}", false, context);
    defer by_string.deinit();
    try std.testing.expectEqual(@as(?u32, 3308), by_string.settings.port);
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"port\":\"abc\"}", false, context));
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"port\":-1}", false, context));
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"port\":true}", false, context));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: invalid port \"abc\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: invalid port -1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: \"port\" must be a number or string\n") != null);
}

test "auth output: ssl takes a boolean or a word, and protocol takes a --protocol name" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var off = try parseAuthOutput(std.testing.allocator, "{\"ssl\":false,\"ssl-verify-server-cert\":\"off\",\"protocol\":\"TCP\"}", false, context);
    defer off.deinit();
    try std.testing.expectEqual(@as(?bool, false), off.settings.ssl);
    try std.testing.expectEqual(@as(?bool, false), off.settings.ssl_verify_server_cert);
    try std.testing.expectEqual(@as(?Options.Protocol, .tcp), off.settings.protocol);
    var on = try parseAuthOutput(std.testing.allocator, "{\"ssl\":\"1\"}", false, context);
    defer on.deinit();
    try std.testing.expectEqual(@as(?bool, true), on.settings.ssl);
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"ssl\":\"maybe\"}", false, context));
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"protocol\":\"pipe\"}", false, context));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: \"ssl\" must be true or false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: invalid protocol \"pipe\"\n") != null);
}

test "auth output: null means not set, and a missing password is empty" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try parseAuthOutput(std.testing.allocator, "{\"host\":null,\"port\":null,\"password\":null,\"ssl\":null}", false, context);
    defer output.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), output.settings.host);
    try std.testing.expectEqual(@as(?u32, null), output.settings.port);
    try std.testing.expectEqual(@as(?bool, null), output.settings.ssl);
    try std.testing.expectEqualStrings("", output.password.bytes);
    var missing = try parseAuthOutput(std.testing.allocator, "{\"host\":\"h\"}", false, context);
    defer missing.deinit();
    try std.testing.expectEqualStrings("", missing.password.bytes);
    try std.testing.expectEqualStrings("h", missing.settings.host.?);
}

test "auth output: keys match with - and _ alike, and keys starting with _ are ignored" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try parseAuthOutput(std.testing.allocator, "{\"_expires\":\"2030\",\"_meta\":{\"a\":[1,2]},\"ssl_ca\":\"ca\",\"tls_version\":\"TLSv1.2\"}", false, context);
    defer output.deinit();
    try std.testing.expectEqualStrings("ca", output.settings.ssl_ca.?);
    try std.testing.expectEqualStrings("TLSv1.2", output.settings.tls_version.?);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "auth output: an unknown key fails and names the key" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"hostname\":\"h\"}", false, context));
    try std.testing.expectEqualStrings("auth command: unknown key \"hostname\"\n", stderr.buffered());
}

test "auth output: string settings reject other types, including nested objects and arrays" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [512]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"host\":5}", false, context));
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"host\":{\"name\":\"h\"}}", false, context));
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"password\":[\"pw\"]}", false, context));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: \"host\" must be a string\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "auth command: \"password\" must be a string\n") != null);
}

test "auth output: whitespace around the JSON is ignored" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try parseAuthOutput(std.testing.allocator, " \n\t{\"host\":\"h\"}\r\n  ", false, context);
    defer output.deinit();
    try std.testing.expectEqualStrings("h", output.settings.host.?);
    try std.testing.expect(output.json_error == null);
}

test "auth output: JSON cut off by the output limit is an error, not a password" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    try std.testing.expectError(error.AuthCommandFailed, parseAuthOutput(std.testing.allocator, "{\"host\":\"h", true, context));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "cut off") != null);
    var fallback = try parseAuthOutput(std.testing.allocator, "{\"host\":\"h", false, context);
    defer fallback.deinit();
    try std.testing.expectEqualStrings("{\"host\":\"h", fallback.password.bytes);
}

test "auth command output that is JSON reaches the settings through runCommand" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [64]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    var output = try runCommand(std.testing.allocator, std.testing.io, "printf '{\"host\":\"db\",\"password\":\"pw\"}'", context);
    defer output.deinit();
    try std.testing.expectEqualStrings("db", output.settings.host.?);
    try std.testing.expectEqualStrings("pw", output.password.bytes);
}

test "auth command output cut off at 64 KiB is an error through runCommand" {
    var env = testEnv();
    defer env.deinit();
    var stderr_buffer: [256]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);
    const context: FetchContext = .{ .interactive = false, .stderr = &stderr, .env = &env };
    const command = "printf '{\"host\":\"'; head -c 70000 /dev/zero | tr '\\0' h";
    try std.testing.expectError(error.AuthCommandFailed, runCommand(std.testing.allocator, std.testing.io, command, context));
    try std.testing.expect(std.mem.indexOf(u8, stderr.buffered(), "cut off") != null);
}
