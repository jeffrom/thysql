//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

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
};

// passes through regular keypresses, handles commands, EOF, etc.
fn read_input(cfg: *const ReplConfig) ReplError!void {
    // var char: u8 = undefined;
    while (cfg.in.takeByte()) |c| {
        std.debug.print("uhh {}\n", .{c});
    } else |err| {
        if (err == Io.Reader.Error.EndOfStream) {
            try cfg.out.printAsciiChar('\n', .{});
            try cfg.out.flush();
            return;
        }
        return err;
    }
}

// test "basic add functionality" {
//     try std.testing.expect(add(3, 7) == 10);
// }
