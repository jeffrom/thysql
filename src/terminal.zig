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

        // output modes - disable post processing
        raw.oflag.OPOST = false;

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

        try posix.tcsetattr(fd, posix.TCSA.FLUSH, raw);

        return .{
            .orig = termios,
            .fd = fd,
        };
    }

    pub fn disable(self: TermState) void {
        posix.tcsetattr(self.fd, posix.TCSA.FLUSH, self.orig) catch {};
    }
};

pub fn columns() u16 {
    const default = 80;
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return default;

        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(stdout_handle, &info) != 0) {
            return @intCast(info.srWindow.Right - info.srWindow.Left + 1);
        }

        const stdout_fd = std.io.getStdout().handle;
        var winsize: posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };

        const err = posix.system.ioctl(stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (posix.errno(err) == .SUCCESS) return winsize.col;
    }
    return default;
}
