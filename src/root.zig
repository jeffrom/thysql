//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const terminal = @import("terminal.zig");
const unicode = @import("unicode.zig");

pub const TermState = terminal.TermState;

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
    /// Override the detected terminal width. Intended for embedders and tests
    /// that do not have a real terminal attached.
    columns: ?usize = null,
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
        self.cols = self.cfg.columns orelse terminal.columns();
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
                if (self.buf.items.len > 0) {
                    try self.editDelete();
                    return ReadEditState.More;
                }
                return ReadEditState.EOF;
            },
            @intFromEnum(KeyCode.BACKSPACE), @intFromEnum(KeyCode.CTRL_H) => {
                try self.editBackspace();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_A) => {
                try self.editStartOfLine();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_B) => {
                try self.editMoveLeft();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_E) => {
                try self.editEndOfLine();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_F) => {
                try self.editMoveRight();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.ESC) => {
                try self.editEscapeSequence();
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
        if (self.buf.items.len + utf8len > MaxLine) {
            return error.LineTooLong;
        }

        const oldLen = self.buf.items.len;
        const insertingAtEnd = self.pos == oldLen;
        try self.buf.resize(self.allocator, oldLen + utf8len);
        @memmove(
            self.buf.items[self.pos + utf8len ..],
            self.buf.items[self.pos..oldLen],
        );
        @memcpy(self.buf.items[self.pos..][0..utf8len], utf8[0..utf8len]);
        self.pos += utf8len;

        if (insertingAtEnd) {
            try self.cfg.out.writeAll(utf8[0..utf8len]);
            try self.cfg.out.flush();
        } else {
            try self.refreshLine();
        }
    }

    fn editBackspace(self: *Repl) !void {
        if (self.pos == 0 or self.buf.items.len == 0) {
            return;
        }

        const newPos = unicode.codepointStartBefore(self.buf.items, self.pos);
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

    fn editStartOfLine(self: *Repl) !void {
        if (self.pos != 0) {
            self.pos = 0;
            try self.refreshLine();
        }
    }

    fn editEndOfLine(self: *Repl) !void {
        if (self.pos != self.buf.items.len) {
            self.pos = self.buf.items.len;
            try self.refreshLine();
        }
    }

    fn editMoveLeft(self: *Repl) !void {
        if (self.pos > 0) {
            self.pos = unicode.codepointStartBefore(self.buf.items, self.pos);
            try self.refreshLine();
        }
    }

    fn editMoveRight(self: *Repl) !void {
        if (self.pos < self.buf.items.len) {
            self.pos += unicode.codepointLenAt(self.buf.items, self.pos);
            try self.refreshLine();
        }
    }

    fn editDelete(self: *Repl) !void {
        if (self.pos < self.buf.items.len) {
            const removedLen = unicode.codepointLenAt(self.buf.items, self.pos);
            const tailStart = self.pos + removedLen;
            const tailLen = self.buf.items.len - tailStart;
            @memmove(
                self.buf.items[self.pos..][0..tailLen],
                self.buf.items[tailStart..],
            );
            self.buf.items.len -= removedLen;
            try self.refreshLine();
        }
    }

    fn takeEscapeByte(self: *Repl) Io.Reader.Error!?u8 {
        return self.cfg.in.takeByte() catch |err| switch (err) {
            Io.Reader.Error.EndOfStream => null,
            else => return err,
        };
    }

    fn editEscapeSequence(self: *Repl) !void {
        const introducer = (try self.takeEscapeByte()) orelse return;

        switch (introducer) {
            '[' => try self.editCsiSequence(),
            'O' => {
                const final = (try self.takeEscapeByte()) orelse return;
                try self.editEscapeFinal(final, null);
            },
            else => {},
        }
    }

    fn editCsiSequence(self: *Repl) !void {
        var parameter: usize = 0;
        var hasParameter = false;
        var parsingFirstParameter = true;

        // A CSI sequence ends with a byte in the 0x40-0x7e range. Only the
        // first numeric parameter selects an editing action; later parameters
        // are usually key modifiers, such as the 5 in ESC [ 1 ; 5 D.
        var sequenceLen: usize = 0;
        while (sequenceLen < 32) : (sequenceLen += 1) {
            const byte = (try self.takeEscapeByte()) orelse return;
            if (byte >= 0x40 and byte <= 0x7e) {
                try self.editEscapeFinal(
                    byte,
                    if (hasParameter) parameter else null,
                );
                return;
            }

            if (parsingFirstParameter and byte >= '0' and byte <= '9') {
                hasParameter = true;
                if (parameter < 1000) parameter = parameter * 10 + byte - '0';
            } else if (byte == ';') {
                parsingFirstParameter = false;
            }
        }
    }

    fn editEscapeFinal(self: *Repl, final: u8, parameter: ?usize) !void {
        switch (final) {
            'C' => try self.editMoveRight(),
            'D' => try self.editMoveLeft(),
            'H' => try self.editStartOfLine(),
            'F' => try self.editEndOfLine(),
            '~' => switch (parameter orelse return) {
                1, 7 => try self.editStartOfLine(),
                3 => try self.editDelete(),
                4, 8 => try self.editEndOfLine(),
                else => {},
            },
            else => {},
        }
    }

    fn refreshLine(self: *Repl) !void {
        const promptWidth = unicode.displayWidth(self.cfg.prompt);
        var start: usize = 0;
        var cursorWidth = unicode.displayWidth(self.buf.items[0..self.pos]);

        // horizontally scroll by whole codepoints until the cursor fits.
        while (start < self.pos and promptWidth + cursorWidth >= self.cols) {
            const codepointLen = unicode.codepointLenAt(self.buf.items, start);
            start += codepointLen;
            cursorWidth = unicode.displayWidth(self.buf.items[start..self.pos]);
        }

        var end = self.buf.items.len;
        var lineWidth = unicode.displayWidth(self.buf.items[start..end]);
        while (end > self.pos and promptWidth + lineWidth > self.cols) {
            const newEnd = unicode.codepointStartBefore(self.buf.items, end);
            end = newEnd;
            lineWidth = unicode.displayWidth(self.buf.items[start..end]);
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

const testKeys = struct {
    const enter = "\r";
    const backspace = "\x7f";
    const ctrl_c = "\x03";
    const ctrl_d = "\x04";
    const left = "\x1b[D";
    const home = "\x1b[H";
    const end = "\x1b[F";
};

fn expectReadline(inputBytes: []const u8, columns: usize, expectedLine: []const u8) !void {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed(inputBytes);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = columns,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings(expectedLine, try repl.readline());
}

test "readline reads an ordinary line" {
    try expectReadline("hello" ++ testKeys.enter, 80, "hello");
}

test "readline backspace removes the previous character" {
    try expectReadline("hello!" ++ testKeys.backspace ++ testKeys.enter, 80, "hello");
}

test "readline home and end reposition the cursor" {
    try expectReadline(
        "middle" ++ testKeys.home ++ "before-" ++ testKeys.end ++ "-after" ++ testKeys.enter,
        80,
        "before-middle-after",
    );
}

test "readline left arrow allows insertion in the middle" {
    try expectReadline("ac" ++ testKeys.left ++ "b" ++ testKeys.enter, 80, "abc");
}

test "readline editing respects UTF-8 boundaries" {
    try expectReadline(
        "aé界" ++ testKeys.left ++ testKeys.backspace ++ testKeys.enter,
        80,
        "a界",
    );
}

test "readline ctrl-c cancels the current line" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("partial" ++ testKeys.ctrl_c);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectError(ReplError.Cancelled, repl.readline());
}

test "readline ctrl-d on an empty line returns EOF" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed(testKeys.ctrl_d);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectError(Io.Reader.Error.EndOfStream, repl.readline());
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

test "move left and right across UTF-8 codepoints" {
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
    try repl.buf.appendSlice(allocator, "aé界🙂");
    repl.pos = repl.buf.items.len;

    try repl.editMoveLeft();
    try std.testing.expectEqual(@as(usize, 6), repl.pos);
    try repl.editMoveLeft();
    try std.testing.expectEqual(@as(usize, 3), repl.pos);
    try repl.editMoveRight();
    try std.testing.expectEqual(@as(usize, 6), repl.pos);
    try repl.editMoveRight();
    try std.testing.expectEqual(repl.buf.items.len, repl.pos);
}

test "escape sequences move across UTF-8 codepoints" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("\x1b[D\x1b[1;5D\x1b[C\x1b[H\x1bOF");
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
    try repl.buf.appendSlice(allocator, "aé界🙂");
    repl.pos = repl.buf.items.len;

    try std.testing.expectEqual(ReadEditState.More, try repl.readEditKey());
    try std.testing.expectEqual(@as(usize, 6), repl.pos);
    try std.testing.expectEqual(ReadEditState.More, try repl.readEditKey());
    try std.testing.expectEqual(@as(usize, 3), repl.pos);
    try std.testing.expectEqual(ReadEditState.More, try repl.readEditKey());
    try std.testing.expectEqual(@as(usize, 6), repl.pos);
    try std.testing.expectEqual(ReadEditState.More, try repl.readEditKey());
    try std.testing.expectEqual(@as(usize, 0), repl.pos);
    try std.testing.expectEqual(ReadEditState.More, try repl.readEditKey());
    try std.testing.expectEqual(repl.buf.items.len, repl.pos);
}

test "delete escape sequence removes one UTF-8 codepoint" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("\x1b[3~");
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
    try repl.buf.appendSlice(allocator, "aé界");
    repl.pos = 1;

    try std.testing.expectEqual(ReadEditState.More, try repl.readEditKey());
    try std.testing.expectEqualStrings("a界", repl.buf.items);
    try std.testing.expectEqual(@as(usize, 1), repl.pos);
}
