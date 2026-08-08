//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const ReplError = Io.Writer.Error || Io.Reader.Error || std.mem.Allocator.Error;

pub const ReplConfig = struct {
    prompt: []const u8,
    in: *Io.Reader,
    out: *Io.Writer,
};

pub const Repl = struct {
    allocator: std.mem.Allocator,
    cfg: *const ReplConfig,
    charbuf: []u8,

    pub fn init(allocator: std.mem.Allocator, cfg: *const ReplConfig) std.mem.Allocator.Error!Repl {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .charbuf = try allocator.alloc(u8, 512),
        };
    }

    pub fn deinit(self: Repl) void {
        self.allocator.free(self.charbuf);
    }

    pub fn loop(self: Repl) ReplError!void {
        try self.cfg.out.printAscii(self.cfg.prompt, .{});
        try self.cfg.out.flush();

        const c = try self.readKey();
        std.debug.print("key: {}\n", .{c});
    }

    fn readKey(self: Repl) Io.Reader.Error!u8 {
        const c = self.cfg.in.takeByte();
        return c;
    }

    pub fn debugMode(self: Repl) ReplError!void {
        //
        var quit: [4]u8 = undefined;
        @memset(&quit, ' ');
        try self.cfg.out.print("key code debugging mode.\n\rPress keys to see codes. Type 'quit' to exit\n\r", .{});
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

// test "basic add functionality" {
//     try std.testing.expect(add(3, 7) == 10);
// }
