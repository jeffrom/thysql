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
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return .ready;

    var fds = [_]posix.pollfd{.{
        .fd = std.Io.File.stdin().handle,
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
