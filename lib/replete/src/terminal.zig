const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

pub const TermState = struct {
    orig: posix.termios,
    fd: i32,

    pub fn enable(fd: i32) !TermState {
        // TODO test passthrough
        // TODO isatty
        const termios: posix.termios = try posix.tcgetattr(fd);
        var raw = termios;

        // input modes: no break, no CR to NL, no parity check, no strip char,
        // no start/stop output control.
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Preserve output post-processing. In particular, the terminal's
        // ONLCR setting makes newlines printed by the caller return to column
        // zero. GNU Readline leaves the output flags unchanged as well.

        // control modes - set 8 bit chars
        raw.cflag.CSIZE = posix.CSIZE.CS8;

        // local modes - echoing off, canonical off, no extended functions,
        // no signal chars (^Z,^C)
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // Return every single byte without a timeout.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        // TCSA.NOW rather than TCSA.FLUSH: FLUSH discards input that is already
        // waiting, so keys typed while a query ran would be lost at the prompt.
        try posix.tcsetattr(fd, posix.TCSA.NOW, raw);

        return .{
            .orig = termios,
            .fd = fd,
        };
    }

    /// Restores the settings from `enable`. Uses TCSA.NOW, not TCSA.FLUSH, so keys
    /// typed while the caller ran a query stay in the input queue for the next line.
    pub fn disable(self: TermState) void {
        posix.tcsetattr(self.fd, posix.TCSA.NOW, self.orig) catch {};
    }
};

pub const Size = struct {
    columns: usize,
    rows: usize,
};

pub fn size() Size {
    const default: Size = .{ .columns = 80, .rows = 24 };
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return default;

        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(stdout_handle, &info) != 0) {
            return .{
                .columns = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
                .rows = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
            };
        }
    } else {
        const stdout_fd = std.Io.File.stdout().handle;
        var winsize: posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };

        const err = posix.system.ioctl(stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (posix.errno(err) == .SUCCESS and winsize.col > 0 and winsize.row > 0) {
            return .{ .columns = winsize.col, .rows = winsize.row };
        }
    }
    return default;
}

pub fn columns() usize {
    return size().columns;
}

/// What `waitInput` saw on the process standard input.
pub const Wait = enum {
    /// Input can be read, or the read will fail.
    ready,
    /// The time ran out with no input.
    timeout,
    /// A signal, such as a window resize, ended the wait.
    interrupted,
};

/// Waits up to `timeout_ms` for input on the process standard input. A negative timeout waits
/// without a limit. Unlike `std.posix.poll`, a signal does not restart the wait: it returns
/// `interrupted`, so that the caller can react to it. Where polling is not available, the
/// wait reports `ready`, and the caller reads as it would without a wait.
pub fn waitInput(timeout_ms: i32) Wait {
    return waitFd(std.Io.File.stdin().handle, timeout_ms);
}

/// `waitInput` for the file descriptor `fd`.
pub fn waitFd(fd: posix.fd_t, timeout_ms: i32) Wait {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return .ready;

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const rc = posix.system.poll(&fds, 1, timeout_ms);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) .timeout else .ready,
        .INTR => .interrupted,
        // A failed poll reads as ready, so the read that follows reports the error.
        else => .ready,
    };
}

/// Wait briefly for a terminal response on the process standard input. We
/// still read the bytes through its configured reader so existing buffering
/// remains authoritative.
pub fn stdinReady(timeout_ms: i32) bool {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;

    var fds = [_]posix.pollfd{.{
        .fd = std.Io.File.stdin().handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    return (posix.poll(&fds, timeout_ms) catch return false) > 0 and
        fds[0].revents & posix.POLL.IN != 0;
}

/// An sRGB colour, one byte a channel.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// The query sent for the background colour: OSC 11 asking for it, then DA1. Every terminal
/// answers DA1, so the answer to OSC 11 is complete once DA1 comes back.
const background_query = "\x1b]11;?\x1b\\\x1b[c";

/// Asks the terminal for its background colour, waiting at most `timeout_ms` in all. Standard
/// input is in raw mode for the query and is restored on every path. Null when the terminal
/// gives no usable reply, or when the wait is not possible here (Windows, WASI).
pub fn queryBackground(io: std.Io, in_fd: posix.fd_t, out: *std.Io.Writer, timeout_ms: i32) ?Rgb {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    const raw = TermState.enable(in_fd) catch return null;
    defer raw.disable();

    out.writeAll(background_query) catch return null;
    out.flush() catch return null;

    // The DA1 reply is read too, so that it is not left in the input for the line editor. The
    // background found is returned once it has come, or when the time, the input or the buffer runs out.
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var reply: [128]u8 = undefined;
    var len: usize = 0;
    var found: ?Rgb = null;
    while (len < reply.len) {
        const elapsed_ms: i64 = @intCast(@divTrunc(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds, 1_000_000));
        const remaining = timeout_ms - elapsed_ms;
        if (remaining <= 0) return found;
        if (waitFd(in_fd, @intCast(remaining)) != .ready) return found;
        const count = posix.read(in_fd, reply[len..]) catch return found;
        if (count == 0) return found;
        len += count;
        const scan = scanReply(reply[0..len]);
        found = scan.background;
        if (scan.done) return found;
    }
    return found;
}

/// What the bytes read so far say about the background query.
pub const Reply = struct {
    /// The OSC 11 colour, once its reply is complete and parses. Null otherwise.
    background: ?Rgb = null,
    /// Whether the DA1 reply has come. Terminals answer in order, so it comes after any OSC 11 reply.
    done: bool = false,
};

/// Reads the reply to `background_query` from `bytes`, which may be only the start of it.
pub fn scanReply(bytes: []const u8) Reply {
    var reply: Reply = .{};
    const osc = "\x1b]11;";
    if (std.mem.indexOf(u8, bytes, osc)) |start| {
        const body = bytes[start + osc.len ..];
        if (oscEnd(body)) |end| reply.background = parseRgb(body[0..end]);
    }
    // DA1 reply: ESC [ ? <params> c
    if (std.mem.indexOf(u8, bytes, "\x1b[?")) |start| {
        reply.done = std.mem.indexOfScalarPos(u8, bytes, start, 'c') != null;
    }
    return reply;
}

/// The index of the terminator of an OSC string in `body`: BEL, or ESC \.
fn oscEnd(body: []const u8) ?usize {
    for (body, 0..) |byte, i| {
        if (byte == 0x07) return i;
        if (byte == 0x1b and i + 1 < body.len and body[i + 1] == '\\') return i;
    }
    return null;
}

/// Parses `rgb:RRRR/GGGG/BBBB`, where each component has one to four hex digits, into 0-255 values.
/// Null when the text is not that form.
pub fn parseRgb(text: []const u8) ?Rgb {
    if (!std.mem.startsWith(u8, text, "rgb:")) return null;
    var parts = std.mem.splitScalar(u8, text["rgb:".len..], '/');
    const r = scaleComponent(parts.next() orelse return null) orelse return null;
    const g = scaleComponent(parts.next() orelse return null) orelse return null;
    const b = scaleComponent(parts.next() orelse return null) orelse return null;
    if (parts.next() != null) return null;
    return .{ .r = r, .g = g, .b = b };
}

/// Scales a hex component of one to four digits to 0-255, rounding.
fn scaleComponent(hex: []const u8) ?u8 {
    if (hex.len < 1 or hex.len > 4) return null;
    for (hex) |c| if (!std.ascii.isHex(c)) return null;
    const value = std.fmt.parseUnsigned(u32, hex, 16) catch return null;
    var max: u32 = 1;
    for (hex) |_| max *= 16;
    max -= 1;
    return @intCast((value * 255 + max / 2) / max);
}

/// Whether `rgb` is a dark colour: its relative luminance, with sRGB weights and no gamma
/// correction, is below one half.
pub fn isDark(rgb: Rgb) bool {
    const luminance = 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b);
    return luminance < 0.5;
}

fn channel(value: u8) f64 {
    return @as(f64, @floatFromInt(value)) / 255.0;
}

test "OSC 11 then DA1 in one read: the colour is found and the reply is done" {
    const both = scanReply("\x1b]11;rgb:00/00/00\x07\x1b[?62;22c");
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, both.background.?);
    try std.testing.expect(both.done);

    // Both endings of the OSC string, with 2- and 4-digit components.
    const bel = scanReply("\x1b]11;rgb:1e1e/1e1e/2e2e\x07\x1b[?1;2c");
    try std.testing.expectEqual(Rgb{ .r = 30, .g = 30, .b = 46 }, bel.background.?);
    try std.testing.expect(bel.done);
    const st = scanReply("\x1b]11;rgb:fa/f4/ef\x1b\\\x1b[?1;2c");
    try std.testing.expectEqual(Rgb{ .r = 250, .g = 244, .b = 239 }, st.background.?);
    try std.testing.expect(st.done);
}

test "OSC 11 alone: the colour is found, but the reply is not done yet" {
    const reply = scanReply("\x1b]11;rgb:1e1e/1e1e/2e2e\x07");
    try std.testing.expectEqual(Rgb{ .r = 30, .g = 30, .b = 46 }, reply.background.?);
    try std.testing.expect(!reply.done);
}

test "DA1 alone: the reply is done, with no colour" {
    const reply = scanReply("\x1b[?1;2c");
    try std.testing.expectEqual(@as(?Rgb, null), reply.background);
    try std.testing.expect(reply.done);
}

test "OSC 11 and DA1 split across reads: each read adds to what was found" {
    const osc = "\x1b]11;rgb:1e1e/1e1e/2e2e\x07";
    const da1 = "\x1b[?62;22c";

    // The OSC string is cut in the middle: nothing is found yet.
    const first = scanReply("\x1b]11;rgb:1e1e/1e");
    try std.testing.expectEqual(@as(?Rgb, null), first.background);
    try std.testing.expect(!first.done);

    // The OSC string is complete, and the DA1 reply has begun.
    const second = scanReply(osc ++ "\x1b[?62;");
    try std.testing.expectEqual(Rgb{ .r = 30, .g = 30, .b = 46 }, second.background.?);
    try std.testing.expect(!second.done);

    // The DA1 reply is complete.
    const third = scanReply(osc ++ da1);
    try std.testing.expectEqual(Rgb{ .r = 30, .g = 30, .b = 46 }, third.background.?);
    try std.testing.expect(third.done);

    // DA1 split with the OSC reply in an earlier read, cut before its final byte.
    const cut = scanReply(osc ++ "\x1b[?62;22");
    try std.testing.expect(!cut.done);
}

test "a reply still arriving is not done, and a garbled OSC 11 reply has no colour" {
    try std.testing.expectEqual(Reply{}, scanReply(""));
    try std.testing.expectEqual(@as(?Rgb, null), scanReply("\x1b]11;rgb:1e1e/1e").background);
    try std.testing.expectEqual(@as(?Rgb, null), scanReply("\x1b]11;rgb:1e1e/1e1e/2e2e\x1b").background);
    try std.testing.expectEqual(@as(?Rgb, null), scanReply("\x1b]11;hsl:1/2/3\x07").background);
    try std.testing.expectEqual(@as(?Rgb, null), scanReply("\x1b]11;rgb:zz/00/00\x07").background);
}

test "parseRgb scales components of one to four digits to 0-255" {
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, parseRgb("rgb:ff/80/0").?);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 128, .b = 0 }, parseRgb("rgb:ffff/8080/0000").?);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, parseRgb("rgb:0/0/0").?);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, parseRgb("rgb:f/fff/fff").?);
}

test "parseRgb rejects anything else" {
    const bad = [_][]const u8{ "", "rgb:", "rgb:ff/ff", "rgb:ff/ff/ff/ff", "rgb:/ff/ff", "rgb:fffff/0/0", "rgba:ff/ff/ff/ff", "rgb:g0/0/0" };
    for (bad) |text| {
        try std.testing.expectEqual(@as(?Rgb, null), parseRgb(text));
    }
}

test "isDark is true for dark colours and false for light ones" {
    try std.testing.expect(isDark(.{ .r = 30, .g = 30, .b = 46 }));
    try std.testing.expect(isDark(.{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expect(!isDark(.{ .r = 239, .g = 241, .b = 245 }));
    try std.testing.expect(!isDark(.{ .r = 255, .g = 255, .b = 255 }));
}
