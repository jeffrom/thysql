//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ReplConfig = struct {
    prompt: []const u8,
    in: *Io.Reader,
    out: *Io.Writer,
};

const ReplContext = struct {
    cfg: *const ReplConfig,
    charbuf: []u8,
};

const ReplError = Io.Writer.Error || Io.Reader.Error || std.mem.Allocator.Error;

pub fn repl_loop(allocator: std.mem.Allocator, cfg: *const ReplConfig) ReplError!void {
    const ctx = ReplContext{
        .cfg = cfg,
        .charbuf = try allocator.alloc(u8, 512),
    };
    try cfg.out.printAscii(cfg.prompt, .{});
    try cfg.out.flush();

    const c = try read_key(&ctx);
    std.debug.print("key: {}\n", .{c});
}

fn read_key(ctx: *const ReplContext) Io.Reader.Error!u8 {
    const c = ctx.cfg.in.takeByte();

    return c;
}

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
