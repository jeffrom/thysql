//! By convention, root.zig is the root source file when making a package.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub const ReplError = Io.Writer.Error || Io.Reader.Error || std.mem.Allocator.Error || error{
    Cancelled,
};

const ReadEditState = enum {
    More,
    Done,
    Cancel,
    EOF,
};

const KeyCode = enum(u8) {
    KEY_NULL = 0,
    CTRL_A = 1,
    CTRL_B = 2,
    CTRL_C = 3,
    CTRL_D = 4,
    CTRL_E = 5,
    CTRL_F = 6,
    CTRL_H = 8,
    TAB = 9,
    CTRL_K = 11,
    CTRL_L = 12,
    ENTER = 13,
    CTRL_N = 14,
    CTRL_P = 16,
    CTRL_T = 20,
    CTRL_U = 21,
    CTRL_W = 23,
    ESC = 27,
    BACKSPACE = 127,
};

const MaxLine = 1024 * 1024;

pub const ReplConfig = struct {
    prompt: []const u8,
    in: *Io.Reader,
    out: *Io.Writer,
};

pub const Repl = struct {
    allocator: std.mem.Allocator,
    cfg: *const ReplConfig,
    buf: std.ArrayList(u8),
    pos: usize,
    cols: usize,

    pub fn init(allocator: std.mem.Allocator, cfg: *const ReplConfig) !Repl {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .buf = try std.ArrayList(u8).initCapacity(allocator, 1024),
            .pos = 0,
            .cols = 0,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.buf.deinit(self.allocator);
        // self.allocator.free(self.buf);
    }

    pub fn readline(self: *Repl) ![]u8 {
        try self.editStart();

        while (true) {
            const state: ReadEditState = try self.readEditKey();
            switch (state) {
                ReadEditState.EOF => {
                    return Io.Reader.Error.EndOfStream;
                },

                ReadEditState.Cancel => {
                    return ReplError.Cancelled;
                    // try self.editStart();
                    // try self.refreshLine();
                },
                ReadEditState.Done => {
                    return self.buf.items;
                },
                ReadEditState.More => {
                    continue;
                },
            }
        }
        // std.debug.print("key: {}\n", .{c});
    }

    fn editStart(self: *Repl) !void {
        self.buf.clearRetainingCapacity();
        self.pos = 0;
        self.cols = getTermColumns();
        // std.debug.print("\r\neditStart: {} cols, line buffer {}/{}\r\n", .{ self.cols, self.pos, self.buf.capacity });

        try self.cfg.out.printAscii(self.cfg.prompt, .{});
        try self.cfg.out.flush();
    }

    fn readEditKey(self: *Repl) !ReadEditState {
        const c = try self.cfg.in.takeByte();
        // std.debug.print("readEditKey c: {c}\n", .{c});
        switch (c) {
            @intFromEnum(KeyCode.ENTER) => {
                return ReadEditState.Done;
            },
            @intFromEnum(KeyCode.CTRL_C) => {
                return ReadEditState.Cancel;
            },
            @intFromEnum(KeyCode.CTRL_D) => {
                // TODO only if the line is empty should we exit
                // otherwise remove the char to the right of the cursor
                return ReadEditState.EOF;
            },
            @intFromEnum(KeyCode.BACKSPACE), @intFromEnum(KeyCode.CTRL_H) => {
                try self.editBackspace();
                return ReadEditState.More;
            },
            else => {
                var utf8: [4]u8 = undefined;
                const utf8len = try std.unicode.utf8ByteSequenceLength(c);
                utf8[0] = c;
                if (utf8len > 1) {
                    // TODO read these all at once
                    for (1..utf8len) |i| {
                        utf8[i] = try self.cfg.in.takeByte();
                    }
                } else if (!std.ascii.isPrint(c)) {
                    std.debug.print("\r\nunprintable unhandled character: 0x{x}\r\n", .{c});
                    return ReadEditState.More;
                }

                try self.editInsert(utf8, utf8len);
                return ReadEditState.More;
            },
        }

        return ReadEditState.Done;
    }

    fn editInsert(self: *Repl, utf8: [4]u8, utf8len: usize) !void {
        if (self.pos + utf8len >= MaxLine) {
            return error.LineTooLong;
        }
        try self.buf.appendSlice(self.allocator, utf8[0..utf8len]);

        try self.cfg.out.writeAll(utf8[0..utf8len]);
        try self.cfg.out.flush();
        self.pos += utf8len;
    }

    fn editBackspace(self: *Repl) !void {
        if (self.pos == 0 or self.buf.items.len == 0) {
            return;
        }

        const newPos = utf8CodepointStartBefore(self.buf.items, self.pos);
        const removedLen = self.pos - newPos;

        const tailLen = self.buf.items.len - self.pos;
        @memmove(
            self.buf.items[newPos..][0..tailLen],
            self.buf.items[self.pos..],
        );
        self.buf.items.len -= removedLen;
        self.pos = newPos;

        try self.refreshLine();
    }

    fn refreshLine(self: *Repl) !void {
        const promptWidth = utf8DisplayWidth(self.cfg.prompt);
        var start: usize = 0;
        var cursorWidth = utf8DisplayWidth(self.buf.items[0..self.pos]);

        // horizontally scroll by whole codepoints until the cursor fits.
        while (start < self.pos and promptWidth + cursorWidth >= self.cols) {
            const codepointLen = utf8CodepointLenAt(self.buf.items, start);
            start += codepointLen;
            cursorWidth = utf8DisplayWidth(self.buf.items[start..self.pos]);
        }

        var end = self.buf.items.len;
        var lineWidth = utf8DisplayWidth(self.buf.items[start..end]);
        while (end > self.pos and promptWidth + lineWidth > self.cols) {
            const newEnd = utf8CodepointStartBefore(self.buf.items, end);
            end = newEnd;
            lineWidth = utf8DisplayWidth(self.buf.items[start..end]);
        }

        // CR moves the cursor to column zero without advancing to a new line.
        try self.cfg.out.writeAll("\r");
        try self.cfg.out.writeAll(self.cfg.prompt);
        try self.cfg.out.writeAll(self.buf.items[start..end]);

        // CSI 0 K erases from the cursor to the end of the line. Then CR
        // again.
        try self.cfg.out.writeAll("\x1b[0K\r");

        const cursorColumn = promptWidth + cursorWidth;
        if (cursorColumn > 0) {
            // CSI n C moves the cursor n display columns to the right.
            try self.cfg.out.print("\x1b[{d}C", .{cursorColumn});
        }
        try self.cfg.out.flush();
    }

    pub fn debugMode(self: Repl) ReplError!void {
        //
        var quit: [4]u8 = undefined;
        @memset(&quit, ' ');
        try self.cfg.out.print("key code debugging mode.\r\nPress keys to see codes. Type 'quit' to exit\r\n", .{});
        try self.cfg.out.flush();

        while (true) {
            const c = self.cfg.in.takeByte() catch |err| switch (err) {
                Io.Reader.Error.EndOfStream => {
                    continue;
                },
                else => return err,
            };

            // shift string to left
            std.mem.rotate(u8, &quit, 1);
            quit[quit.len - 1] = c;
            if (std.mem.eql(u8, &quit, "quit")) break;

            try self.cfg.out.print("'{c}' 0x{x} ({d: >3}) (type quit to exit)\n", .{ if (std.ascii.isPrint(c)) c else '?', c, c });
            try self.cfg.out.print("\r", .{}); // go to left edge manually
            try self.cfg.out.flush();
        }
    }
};

pub const TermState = struct {
    orig: posix.termios,
    fd: i32,

    pub fn enable(fd: i32) !TermState {
        // TODO test passthrough
        // if (assumeTty) {
        //     return;
        // }
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

        // local modes - choing off, canonical off, no extended functions,
        // no signal chars (^Z,^C)
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // control chars - set return condition: min number of bytes and timer.
        // We want read to return every single byte, without timeout.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1; // 1 byte
        raw.cc[@intFromEnum(posix.V.TIME)] = 0; // no timer

        try posix.tcsetattr(fd, posix.TCSA.FLUSH, raw);

        // Ask the terminal to wrap paste input between ESC[200~ and ESC[201~.
        // if (write(rawmode_output, "\x1b[?2004h", 8) == -1) {}
        return .{
            .orig = termios,
            .fd = fd,
        };
    }

    pub fn disable(self: TermState) void {
        posix.tcsetattr(self.fd, posix.TCSA.FLUSH, self.orig) catch {};
    }
};

fn utf8CodepointStartBefore(buf: []const u8, pos: usize) usize {
    std.debug.assert(pos > 0 and pos <= buf.len);

    var start = pos - 1;
    while (start > 0 and buf[start] & 0xc0 == 0x80) : (start -= 1) {}
    return start;
}

fn utf8CodepointLenAt(buf: []const u8, pos: usize) usize {
    std.debug.assert(pos < buf.len);

    const len = std.unicode.utf8ByteSequenceLength(buf[pos]) catch return 1;
    if (pos + len > buf.len) return 1;
    _ = std.unicode.utf8Decode(buf[pos .. pos + len]) catch return 1;
    return len;
}

fn isZeroWidthCodepoint(cp: u21) bool {
    return cp == 0x200d or // Zero-width joiner
        cp == 0xfe0e or cp == 0xfe0f or // Variation selectors
        (cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or
        (cp >= 0x1f3fb and cp <= 0x1f3ff); // Emoji skin tones
}

fn isWideCodepoint(cp: u21) bool {
    return cp >= 0x1100 and
        (cp <= 0x115f or
            cp == 0x2329 or cp == 0x232a or
            (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
            (cp >= 0xac00 and cp <= 0xd7a3) or
            (cp >= 0xf900 and cp <= 0xfaff) or
            (cp >= 0xfe10 and cp <= 0xfe19) or
            (cp >= 0xfe30 and cp <= 0xfe6f) or
            (cp >= 0xff00 and cp <= 0xff60) or
            (cp >= 0xffe0 and cp <= 0xffe6) or
            (cp >= 0x1f1e6 and cp <= 0x1f1ff) or
            (cp >= 0x1f300 and cp <= 0x1faff) or
            (cp >= 0x20000 and cp <= 0x2ffff));
}

fn ansiCsiLen(bytes: []const u8) usize {
    if (bytes.len < 2 or bytes[0] != 0x1b or bytes[1] != '[') return 0;

    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
    if (i == bytes.len or bytes[i] < 0x40 or bytes[i] > 0x7e) return 0;
    return i + 1;
}

fn utf8DisplayWidth(bytes: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    var afterZwj = false;

    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            const escapeLen = ansiCsiLen(bytes[i..]);
            if (escapeLen > 0) {
                i += escapeLen;
                continue;
            }
        }

        const codepointLen = utf8CodepointLenAt(bytes, i);
        const cp = std.unicode.utf8Decode(bytes[i .. i + codepointLen]) catch {
            width += 1;
            i += 1;
            continue;
        };

        if (afterZwj) {
            afterZwj = false;
        } else if (!isZeroWidthCodepoint(cp)) {
            width += if (isWideCodepoint(cp)) 2 else 1;
        }
        if (cp == 0x200d) afterZwj = true;
        i += codepointLen;
    }
    return width;
}

fn getTermColumns() u16 {
    const default = 80;
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const stdout_handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch return default;

        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (windows.kernel32.GetConsoleScreenBufferInfo(stdout_handle, &info) != 0) {
            const cols = @as(u16, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
            return cols;
        } else {
            const stdout_fd = std.io.getStdout().handle;
            var winsize: posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };

            const err = posix.system.ioctl(stdout_fd, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (posix.errno(err) == .SUCCESS) {
                return winsize.col;
            }
        }
    }
    return default;
}

// test "basic add functionality" {
//     try std.testing.expect(add(3, 7) == 10);
// }

test "UTF-8 codepoint boundaries and display widths" {
    const text = "aé界🙂";
    try std.testing.expectEqual(@as(usize, 6), utf8CodepointStartBefore(text, text.len));
    try std.testing.expectEqual(@as(usize, 3), utf8CodepointStartBefore(text, 6));
    try std.testing.expectEqual(@as(usize, 2), utf8DisplayWidth("界"));
    try std.testing.expectEqual(@as(usize, 2), utf8DisplayWidth("🙂"));
    try std.testing.expectEqual(@as(usize, 1), utf8DisplayWidth("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), utf8DisplayWidth("👩\u{200d}💻"));
    try std.testing.expectEqual(@as(usize, 3), utf8DisplayWidth("\x1b[32m好\x1b[0m!"));
}

test "backspace removes one UTF-8 codepoint and refreshes the cursor" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("");
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();
    repl.cols = 80;
    try repl.buf.appendSlice(allocator, "aé界z");
    repl.pos = 6; // Immediately after 界, with z to the right of the cursor.

    try repl.editBackspace();

    try std.testing.expectEqualStrings("aéz", repl.buf.items);
    try std.testing.expectEqual(@as(usize, 3), repl.pos);
    try std.testing.expectEqualStrings("\r> aéz\x1b[0K\r\x1b[4C", output.written());
}
