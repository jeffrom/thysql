//! Copies text to the clipboard for `\y`. `copy` tries the backends in order: the
//! `--clipboard-command`, OSC 52 over SSH, the platform tools, then OSC 52 as the
//! fallback. `osc52` is pure, so it is tested without a terminal.

const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;

pub const Backend = enum {
    command,
    osc52,
    pbcopy,
    wl_copy,
    xclip,
    xsel,

    /// The name shown in messages.
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .command => "clipboard-command",
            .osc52 => "OSC 52",
            .pbcopy => "pbcopy",
            .wl_copy => "wl-copy",
            .xclip => "xclip",
            .xsel => "xsel",
        };
    }
};

pub const Outcome = union(enum) {
    copied: Backend,
    /// The text is over `osc52_max_bytes`, so the escape was not sent.
    too_large,
    /// The backend started and failed, or the configured command could not run.
    failed: Backend,
};

pub const Config = struct {
    /// From `--clipboard-command`. Empty means the platform tools.
    command: []const u8 = "",
    /// Largest text sent with OSC 52. Terminals may cut longer escapes short.
    osc52_max_bytes: u64 = 100_000,
    /// Read for $SSH_TTY, $SSH_CONNECTION and $WAYLAND_DISPLAY. Null reads none of them.
    env: ?*const Environ.Map = null,
};

/// Copies `bytes` with the first backend that works. OSC 52 is written to `terminal`, which is
/// the real terminal output, so the escape stays out of the tee file.
pub fn copy(io: std.Io, config: Config, terminal: *std.Io.Writer, bytes: []const u8) !Outcome {
    if (config.command.len > 0) {
        return switch (runCopier(io, &.{ "/bin/sh", "-c", config.command }, bytes)) {
            .copied => .{ .copied = .command },
            .failed, .missing => .{ .failed = .command },
        };
    }
    if (envSet(config.env, "SSH_TTY") or envSet(config.env, "SSH_CONNECTION")) {
        return sendOsc52(terminal, config.osc52_max_bytes, bytes);
    }
    if (builtin.os.tag == .macos) {
        if (tryTool(io, .pbcopy, &.{"pbcopy"}, bytes)) |outcome| return outcome;
    } else {
        if (envSet(config.env, "WAYLAND_DISPLAY")) {
            if (tryTool(io, .wl_copy, &.{"wl-copy"}, bytes)) |outcome| return outcome;
        }
        if (tryTool(io, .xclip, &.{ "xclip", "-selection", "clipboard" }, bytes)) |outcome| return outcome;
        if (tryTool(io, .xsel, &.{ "xsel", "--clipboard", "--input" }, bytes)) |outcome| return outcome;
    }
    return sendOsc52(terminal, config.osc52_max_bytes, bytes);
}

/// Writes the OSC 52 escape that sets the clipboard to `bytes`: the text in base64 for the
/// clipboard selection `c`, ended with ST (ESC \).
pub fn osc52(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeAll("\x1b]52;c;");
    try std.base64.standard.Encoder.encodeWriter(out, bytes);
    try out.writeAll("\x1b\\");
}

fn sendOsc52(terminal: *std.Io.Writer, max_bytes: u64, bytes: []const u8) !Outcome {
    if (bytes.len > max_bytes) {
        return .too_large;
    }
    try osc52(terminal, bytes);
    try terminal.flush();
    return .{ .copied = .osc52 };
}

/// One platform tool. Null when the tool is not installed, so the next backend is tried.
fn tryTool(io: std.Io, backend: Backend, argv: []const []const u8, bytes: []const u8) ?Outcome {
    return switch (runCopier(io, argv, bytes)) {
        .copied => .{ .copied = backend },
        .failed => .{ .failed = backend },
        .missing => null,
    };
}

const Run = enum { copied, failed, missing };

/// Starts `argv` with `bytes` on stdin and waits for it. Its stdout is ignored, so a clipboard
/// tool that forks to keep serving the selection does not hold the terminal.
fn runCopier(io: std.Io, argv: []const []const u8, bytes: []const u8) Run {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
    }) catch return .missing;

    var buffer: [4096]u8 = undefined;
    var stdin = child.stdin.?.writerStreaming(io, &buffer);
    const written = blk: {
        stdin.interface.writeAll(bytes) catch break :blk false;
        stdin.interface.flush() catch break :blk false;
        break :blk true;
    };
    child.stdin.?.close(io);
    child.stdin = null;

    const term = child.wait(io) catch return .failed;
    if (!written) return .failed;
    return switch (term) {
        .exited => |code| if (code == 0) .copied else .failed,
        else => .failed,
    };
}

fn envSet(env: ?*const Environ.Map, name: []const u8) bool {
    const map = env orelse return false;
    const value = map.get(name) orelse return false;
    return value.len > 0;
}

test "osc52 sends the text in base64 and ends with ST" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try osc52(&out, "hi");
    try std.testing.expectEqualStrings("\x1b]52;c;aGk=\x1b\\", out.buffered());
}

test "osc52 refuses text over its limit and writes nothing" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const outcome = try sendOsc52(&out, 2, "abc");
    try std.testing.expectEqual(Outcome.too_large, outcome);
    try std.testing.expectEqualStrings("", out.buffered());

    const sent = try sendOsc52(&out, 3, "abc");
    try std.testing.expectEqual(Backend.osc52, sent.copied);
    try std.testing.expectEqualStrings("\x1b]52;c;YWJj\x1b\\", out.buffered());
}

test "a configured clipboard command gets the text on stdin" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/clip.txt", .{&tmp.sub_path});
    defer std.testing.allocator.free(path);
    const command = try std.fmt.allocPrint(std.testing.allocator, "cat > {s}", .{path});
    defer std.testing.allocator.free(command);

    var terminal_buffer: [64]u8 = undefined;
    var terminal: std.Io.Writer = .fixed(&terminal_buffer);
    const outcome = try copy(io, .{ .command = command }, &terminal, "a\tb\n");
    try std.testing.expectEqual(Backend.command, outcome.copied);
    try std.testing.expectEqualStrings("", terminal.buffered());

    const contents = try std.Io.Dir.readFileAlloc(.cwd(), io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("a\tb\n", contents);

    const failing = try copy(io, .{ .command = "exit 3" }, &terminal, "x");
    try std.testing.expectEqual(Backend.command, failing.failed);
}
