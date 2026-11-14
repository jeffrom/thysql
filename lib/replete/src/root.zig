//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const display = @import("display.zig");
const terminal = @import("terminal.zig");
const unicode = @import("unicode.zig");
const history_mod = @import("history.zig");

pub const kitty = @import("kitty.zig");
pub const History = history_mod.History;
pub const HistoryOptions = history_mod.Options;
pub const HistoryDeduplication = history_mod.Deduplication;
const kill = @import("kill.zig");

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

const LastCommand = enum {
    other,
    kill,
    yank,
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
    CTRL_Q = 17,
    CTRL_R = 18,
    CTRL_S = 19,
    CTRL_T = 20,
    CTRL_U = 21,
    CTRL_V = 22,
    CTRL_W = 23,
    CTRL_Y = 25,
    ESC = 27,
    BACKSPACE = 127,
};

const MaxLine = 1024 * 1024;

pub const ReplConfig = struct {
    /// Text or a richer encoded prompt. Kitty PNG prompts can be produced with
    /// kitty.pngPrompt while ordinary string prompts require no special setup.
    prompt: []const u8,
    /// Used when prompt contains Kitty graphics commands but the terminal does
    /// not answer the Kitty graphics capability query.
    fallback_prompt: ?[]const u8 = null,
    in: *Io.Reader,
    out: *Io.Writer,
    /// Override the detected terminal width. Intended for embedders and tests
    /// that do not have a real terminal attached.
    columns: ?usize = null,
    /// Override the detected terminal height. Intended for embedders and tests.
    rows: ?usize = null,
    /// Ask the terminal to delimit pasted text so it can be inserted without
    /// executing editing commands. Matches GNU Readline's default.
    bracketed_paste: bool = true,
    /// Optional command history used by navigation and search. Like GNU
    /// Readline, adding accepted lines remains the caller's responsibility.
    history: ?*History = null,
};

pub const Repl = struct {
    gpa: std.mem.Allocator,
    cfg: *const ReplConfig,
    buf: std.ArrayList(u8),
    pos: usize,
    yankPos: usize, // for cycling the kill ring (ctrl-y, meta-y)
    cols: usize,
    rows: usize,
    rendered_rows: usize,
    rendered_cursor_row: usize,
    quoted_next: bool,
    bracketed_paste_enabled: bool,
    /// Prompt for the next `readline`; see `setPrompt`.
    prompt: []const u8,
    /// Prompt drawn for the current line; `prompt`, or the fallback when Kitty graphics are unavailable.
    active_prompt: []const u8,
    /// Whether the terminal answered the Kitty graphics query. Null until queried.
    kitty_graphics: ?bool,
    kills: kill.Ring,
    history_index: usize,
    saved_line: std.ArrayList(u8),
    saved_line_valid: bool,
    last_search: std.ArrayList(u8),
    lastCommand: LastCommand = .other,

    pub fn init(gpa: std.mem.Allocator, cfg: *const ReplConfig) !Repl {
        return .{
            .gpa = gpa,
            .cfg = cfg,
            .buf = try std.ArrayList(u8).initCapacity(gpa, 1024),
            .pos = 0,
            .yankPos = 0,
            .cols = 0,
            .rows = 0,
            .rendered_rows = 0,
            .rendered_cursor_row = 0,
            .quoted_next = false,
            .bracketed_paste_enabled = false,
            .prompt = cfg.prompt,
            .active_prompt = cfg.prompt,
            .kitty_graphics = null,
            .kills = try kill.Ring.init(gpa),
            .history_index = 0,
            .saved_line = .empty,
            .saved_line_valid = false,
            .last_search = .empty,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.buf.deinit(self.gpa);
        self.kills.deinit();
        self.saved_line.deinit(self.gpa);
        self.last_search.deinit(self.gpa);
    }

    /// Sets the prompt used by later `readline` calls. The slice is not copied:
    /// it must stay valid until the prompt is changed or the last call finishes.
    pub fn setPrompt(self: *Repl, prompt: []const u8) void {
        self.prompt = prompt;
    }

    /// Sets the prompt with `setPrompt`, then reads one line.
    pub fn readlinePrompt(self: *Repl, prompt: []const u8) ![]u8 {
        self.setPrompt(prompt);
        return self.readline();
    }

    /// Reads one line and returns it without the newline. The slice points into
    /// the Repl's own buffer, so it is valid only until the next call that reads
    /// or edits a line, or until `deinit`. Copy it to keep it longer, or use
    /// `readlineOwned`.
    pub fn readline(self: *Repl) ![]u8 {
        errdefer {
            self.disableBracketedPaste() catch {};
            self.cfg.out.flush() catch {};
        }
        try self.editStart();

        while (true) {
            const state: ReadEditState = try self.readEditKey();
            switch (state) {
                ReadEditState.EOF => {
                    try self.finishAtBottom();
                    return Io.Reader.Error.EndOfStream;
                },

                ReadEditState.Cancel => {
                    try self.finishAtBottom();
                    return ReplError.Cancelled;
                    // try self.editStart();
                    // try self.refreshLine();
                },
                ReadEditState.Done => {
                    try self.saveEditedHistoryEntry();
                    try self.finishAtBottom();
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
        const size = terminal.size();
        self.cols = self.cfg.columns orelse size.columns;
        self.rows = self.cfg.rows orelse size.rows;
        self.rendered_rows = 0;
        self.rendered_cursor_row = 0;
        self.quoted_next = false;
        self.saved_line.clearRetainingCapacity();
        self.saved_line_valid = false;
        self.history_index = if (self.cfg.history) |history| history.len() else 0;

        try self.selectPrompt();

        if (self.cfg.bracketed_paste) {
            try self.cfg.out.writeAll("\x1b[?2004h");
            self.bracketed_paste_enabled = true;
        }
        // Each line may use a different prompt, so its Kitty setup is sent
        // here, once per line, rather than while the line is repainted.
        try self.writePromptSetup();
        try self.refreshLine();
    }

    /// Chooses `active_prompt` for this line. The Kitty graphics query runs at
    /// most once per Repl, and only when a fallback exists for a Kitty prompt.
    fn selectPrompt(self: *Repl) !void {
        self.active_prompt = self.prompt;
        const fallback = self.cfg.fallback_prompt orelse return;
        if (std.mem.indexOf(u8, self.prompt, "\x1b_G") == null) return;
        if (self.kitty_graphics == null) {
            self.kitty_graphics = try self.detectKittyGraphics();
        }
        if (!self.kitty_graphics.?) self.active_prompt = fallback;
    }

    fn writePromptSetup(self: *Repl) !void {
        var i: usize = 0;
        while (i < self.active_prompt.len) {
            const len = display.kittyGraphicsLen(self.active_prompt[i..]);
            if (len > 0) {
                try self.cfg.out.writeAll(self.active_prompt[i .. i + len]);
                i += len;
            } else {
                i += 1;
            }
        }
    }

    const kitty_query_id = 2_147_483_646;

    fn detectKittyGraphics(self: *Repl) !bool {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;

        try self.cfg.out.print(
            "\x1b_Gi={d},s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c",
            .{kitty_query_id},
        );
        try self.cfg.out.flush();

        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(self.gpa);
        while (response.items.len < 4096) {
            if (self.cfg.in.bufferedLen() == 0 and !terminal.stdinReady(200)) return false;
            const byte = self.cfg.in.takeByte() catch return false;
            try response.append(self.gpa, byte);
            if (hasDeviceAttributesResponse(response.items)) break;
        }
        return hasKittyOkResponse(response.items);
    }

    fn hasKittyOkResponse(response: []const u8) bool {
        var expected: [64]u8 = undefined;
        const ok = std.fmt.bufPrint(&expected, "\x1b_Gi={d};OK\x1b\\", .{kitty_query_id}) catch unreachable;
        return std.mem.indexOf(u8, response, ok) != null;
    }

    fn hasDeviceAttributesResponse(response: []const u8) bool {
        var i: usize = 0;
        while (i + 2 < response.len) : (i += 1) {
            if (response[i] != 0x1b or response[i + 1] != '[') continue;
            var end = i + 2;
            while (end < response.len and response[end] >= 0x20 and response[end] <= 0x3f) : (end += 1) {}
            if (end < response.len and response[end] == 'c') return true;
        }
        return false;
    }

    fn readEditKey(self: *Repl) !ReadEditState {
        const c = try self.cfg.in.takeByte();
        var command: LastCommand = .other;
        defer self.lastCommand = command;

        if (self.quoted_next) {
            self.quoted_next = false;
            try self.editInputByte(c, true);
            return ReadEditState.More;
        }
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
            @intFromEnum(KeyCode.CTRL_P) => {
                try self.editPreviousHistory();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_N) => {
                try self.editNextHistory();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_R) => {
                return try self.editIncrementalSearch(.backward);
            },
            @intFromEnum(KeyCode.CTRL_S) => {
                return try self.editIncrementalSearch(.forward);
            },
            @intFromEnum(KeyCode.CTRL_Q), @intFromEnum(KeyCode.CTRL_V) => {
                self.quoted_next = true;
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_K) => {
                command = .kill;
                try self.editKillLine();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_U) => {
                command = .kill;
                try self.editBackwardsKillLine();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.CTRL_Y) => {
                command = .yank;
                try self.editYank();
                return ReadEditState.More;
            },
            @intFromEnum(KeyCode.ESC) => {
                command = try self.editEscapeSequence();
                return ReadEditState.More;
            },
            else => {
                try self.editInputByte(c, false);
                return ReadEditState.More;
            },
        }

        return ReadEditState.Done;
    }

    fn editInputByte(self: *Repl, first: u8, quoted: bool) !void {
        var utf8: [4]u8 = undefined;
        const utf8len = std.unicode.utf8ByteSequenceLength(first) catch 1;
        utf8[0] = first;
        if (utf8len > 1) {
            for (1..utf8len) |i| utf8[i] = try self.cfg.in.takeByte();
        } else if (!quoted and !std.ascii.isPrint(first)) {
            return;
        }
        try self.editInsert(utf8, utf8len);
    }

    fn editInsert(self: *Repl, utf8: [4]u8, utf8len: usize) !void {
        try self.editInsertSlice(utf8[0..utf8len]);
    }

    fn editInsertSlice(self: *Repl, bytes: []const u8) !void {
        if (self.buf.items.len + bytes.len > MaxLine) {
            return error.LineTooLong;
        }

        const oldLen = self.buf.items.len;
        try self.buf.resize(self.gpa, oldLen + bytes.len);
        @memmove(
            self.buf.items[self.pos + bytes.len ..],
            self.buf.items[self.pos..oldLen],
        );
        @memcpy(self.buf.items[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
        try self.refreshLine();
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

    fn replaceBuffer(self: *Repl, line: []const u8, point: ?usize) !void {
        if (line.len > MaxLine) return error.LineTooLong;
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.gpa, line);
        self.pos = @min(point orelse line.len, line.len);
    }

    fn saveEditedHistoryEntry(self: *Repl) !void {
        const history = self.cfg.history orelse return;
        if (self.history_index < history.len()) {
            _ = try history.replace(self.history_index, self.buf.items);
        }
    }

    fn saveUnfinishedLine(self: *Repl) !void {
        if (self.saved_line_valid) return;
        self.saved_line.clearRetainingCapacity();
        try self.saved_line.appendSlice(self.gpa, self.buf.items);
        self.saved_line_valid = true;
    }

    fn editPreviousHistory(self: *Repl) !void {
        const history = self.cfg.history orelse return;
        if (history.len() == 0 or self.history_index == 0) return;

        if (self.history_index == history.len()) {
            try self.saveUnfinishedLine();
        } else {
            try self.saveEditedHistoryEntry();
        }
        self.history_index -= 1;
        try self.replaceBuffer(history.get(self.history_index).?.line, null);
        try self.refreshLine();
    }

    fn editNextHistory(self: *Repl) !void {
        const history = self.cfg.history orelse return;
        if (self.history_index >= history.len()) return;

        try self.saveEditedHistoryEntry();
        self.history_index += 1;
        if (self.history_index == history.len()) {
            try self.replaceBuffer(if (self.saved_line_valid) self.saved_line.items else "", null);
        } else {
            try self.replaceBuffer(history.get(self.history_index).?.line, null);
        }
        try self.refreshLine();
    }

    fn isWordCodepointAt(self: *const Repl, pos: usize) bool {
        const len = unicode.codepointLenAt(self.buf.items, pos);
        const codepoint = std.unicode.utf8Decode(self.buf.items[pos .. pos + len]) catch return false;

        // Readline's default word predicate is iswalnum(3). Zig does not ship
        // Unicode character-category tables, so retain its exact ASCII behavior
        // and regard valid non-ASCII codepoints as word characters.
        return if (codepoint <= 0x7f)
            std.ascii.isAlphanumeric(@intCast(codepoint))
        else
            true;
    }

    fn editBackwardWord(self: *Repl) !void {
        if (self.pos == 0) return;

        var next = self.pos;
        var previous = unicode.codepointStartBefore(self.buf.items, next);
        while (!self.isWordCodepointAt(previous)) {
            next = previous;
            if (next == 0) break;
            previous = unicode.codepointStartBefore(self.buf.items, next);
        }
        while (next > 0) {
            previous = unicode.codepointStartBefore(self.buf.items, next);
            if (!self.isWordCodepointAt(previous)) break;
            next = previous;
        }

        if (next != self.pos) {
            self.pos = next;
            try self.refreshLine();
        }
    }

    fn editForwardWord(self: *Repl) !void {
        if (self.pos == self.buf.items.len) return;

        var next = self.pos;
        while (next < self.buf.items.len and !self.isWordCodepointAt(next)) {
            next += unicode.codepointLenAt(self.buf.items, next);
        }
        while (next < self.buf.items.len and self.isWordCodepointAt(next)) {
            next += unicode.codepointLenAt(self.buf.items, next);
        }

        if (next != self.pos) {
            self.pos = next;
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

    fn editKillLine(self: *Repl) !void {
        if (self.pos == self.buf.items.len) {
            return;
        }

        try self.kills.push(self.buf.items, self.pos, self.buf.items.len, self.lastCommand == .kill);
        self.buf.items.len -= self.buf.items.len - self.pos;

        try self.refreshLine();
    }

    fn editBackwardsKillLine(self: *Repl) !void {
        if (self.pos == 0) {
            return;
        }

        try self.kills.push(self.buf.items, self.pos, 0, self.lastCommand == .kill);

        const headLen = self.buf.items.len - self.pos;
        @memmove(self.buf.items[0..self.pos][0..headLen], self.buf.items[self.pos..self.buf.items.len]);

        self.buf.items.len -= self.pos;
        self.pos = 0;
        try self.refreshLine();
    }

    fn editYank(self: *Repl) !void {
        const k = self.kills.get();
        if (k != null) {
            self.yankPos = self.pos;
            try self.editInsertSlice(k.?);
        }
    }

    fn editYankPop(self: *Repl) !LastCommand {
        if (self.lastCommand != .yank) return .other;

        const previous = self.kills.get() orelse return .other;
        const changed = self.kills.yankPop();
        if (changed) {
            const tail_start = self.yankPos + previous.len;
            const tail_len = self.buf.items.len - tail_start;
            @memmove(
                self.buf.items[self.yankPos..][0..tail_len],
                self.buf.items[tail_start..],
            );
            self.buf.items.len -= previous.len;
            self.pos = self.yankPos;
            try self.editYank();
        }
        return if (changed) .yank else .other;
    }

    const SearchOriginal = struct {
        line: []u8,
        point: usize,
        history_index: usize,

        fn deinit(original: SearchOriginal, gpa: std.mem.Allocator) void {
            gpa.free(original.line);
        }
    };

    fn searchOriginal(self: *Repl) !SearchOriginal {
        return .{
            .line = try self.gpa.dupe(u8, self.buf.items),
            .point = self.pos,
            .history_index = self.history_index,
        };
    }

    fn searchStart(history_len: usize, position: usize, direction: history_mod.Direction) ?usize {
        if (history_len == 0) return null;
        return switch (direction) {
            .backward => if (position >= history_len) history_len - 1 else position,
            .forward => if (position + 1 < history_len) position + 1 else null,
        };
    }

    fn searchNext(history_len: usize, index: usize, direction: history_mod.Direction) ?usize {
        return switch (direction) {
            .backward => if (index == 0) null else index - 1,
            .forward => if (index + 1 < history_len) index + 1 else null,
        };
    }

    fn showIncrementalSearch(
        self: *Repl,
        query: []const u8,
        direction: history_mod.Direction,
        match: ?history_mod.Match,
        failed: bool,
    ) !void {
        const history = self.cfg.history.?;
        const label = switch (direction) {
            .backward => "reverse-i-search",
            .forward => "forward-i-search",
        };
        const prompt = if (failed)
            try std.fmt.allocPrint(self.gpa, "(failed {s})`{s}': ", .{ label, query })
        else
            try std.fmt.allocPrint(self.gpa, "({s})`{s}': ", .{ label, query });
        defer self.gpa.free(prompt);

        const normal_prompt = self.active_prompt;
        self.active_prompt = prompt;
        defer self.active_prompt = normal_prompt;
        if (match) |found| {
            try self.replaceBuffer(history.get(found.index).?.line, found.offset + query.len);
        }
        try self.refreshLine();
    }

    fn acceptSearchMatch(self: *Repl, original: SearchOriginal, match: history_mod.Match) !void {
        const history = self.cfg.history.?;
        if (original.history_index == history.len()) {
            try self.replaceBuffer(original.line, original.point);
            try self.saveUnfinishedLine();
        }
        self.history_index = match.index;
        try self.replaceBuffer(history.get(match.index).?.line, match.offset);
    }

    fn editIncrementalSearch(self: *Repl, initial_direction: history_mod.Direction) !ReadEditState {
        const history = self.cfg.history orelse return .More;
        if (history.len() == 0) return .More;

        const original = try self.searchOriginal();
        defer original.deinit(self.gpa);
        var query: std.ArrayList(u8) = .empty;
        defer query.deinit(self.gpa);
        var direction = initial_direction;
        var match: ?history_mod.Match = null;

        if (searchStart(history.len(), original.history_index, direction)) |start| {
            match = history.find(query.items, start, direction, .substring);
        }
        try self.showIncrementalSearch(query.items, direction, match, match == null);

        while (true) {
            const byte = try self.cfg.in.takeByte();
            switch (byte) {
                @intFromEnum(KeyCode.ENTER) => {
                    if (match) |found| {
                        try self.acceptSearchMatch(original, found);
                        try self.refreshLine();
                        return .Done;
                    }
                    try self.replaceBuffer(original.line, original.point);
                    self.history_index = original.history_index;
                    try self.refreshLine();
                    return .More;
                },
                @intFromEnum(KeyCode.ESC), @intFromEnum(KeyCode.CTRL_C), 7 => {
                    try self.replaceBuffer(original.line, original.point);
                    self.history_index = original.history_index;
                    try self.refreshLine();
                    return .More;
                },
                @intFromEnum(KeyCode.CTRL_R), @intFromEnum(KeyCode.CTRL_S) => {
                    direction = if (byte == @intFromEnum(KeyCode.CTRL_R)) .backward else .forward;
                    const start = if (match) |found|
                        searchNext(history.len(), found.index, direction)
                    else
                        searchStart(history.len(), original.history_index, direction);
                    match = if (start) |at| history.find(query.items, at, direction, .substring) else null;
                },
                @intFromEnum(KeyCode.BACKSPACE), @intFromEnum(KeyCode.CTRL_H) => {
                    if (query.items.len > 0) {
                        query.items.len = unicode.codepointStartBefore(query.items, query.items.len);
                    }
                    const start = searchStart(history.len(), original.history_index, direction);
                    match = if (start) |at| history.find(query.items, at, direction, .substring) else null;
                },
                else => {
                    if (!std.ascii.isPrint(byte) and byte < 0x80) {
                        if (match) |found| try self.acceptSearchMatch(original, found) else {
                            try self.replaceBuffer(original.line, original.point);
                            self.history_index = original.history_index;
                        }
                        switch (byte) {
                            @intFromEnum(KeyCode.CTRL_A) => try self.editStartOfLine(),
                            @intFromEnum(KeyCode.CTRL_B) => try self.editMoveLeft(),
                            @intFromEnum(KeyCode.CTRL_D) => try self.editDelete(),
                            @intFromEnum(KeyCode.CTRL_E) => try self.editEndOfLine(),
                            @intFromEnum(KeyCode.CTRL_F) => try self.editMoveRight(),
                            else => try self.refreshLine(),
                        }
                        return .More;
                    }
                    const utf8_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                    try query.append(self.gpa, byte);
                    for (1..utf8_len) |_| try query.append(self.gpa, try self.cfg.in.takeByte());
                    const start = searchStart(history.len(), original.history_index, direction);
                    match = if (start) |at| history.find(query.items, at, direction, .substring) else null;
                },
            }
            try self.showIncrementalSearch(query.items, direction, match, match == null);
        }
    }

    fn editNonIncrementalSearch(self: *Repl, direction: history_mod.Direction) !void {
        const history = self.cfg.history orelse return;
        if (history.len() == 0) return;
        const original = try self.searchOriginal();
        defer original.deinit(self.gpa);

        const normal_prompt = self.active_prompt;
        self.active_prompt = ": ";
        try self.replaceBuffer("", 0);
        try self.refreshLine();

        var cancelled = false;
        while (true) {
            const byte = try self.cfg.in.takeByte();
            switch (byte) {
                @intFromEnum(KeyCode.ENTER) => break,
                @intFromEnum(KeyCode.ESC), @intFromEnum(KeyCode.CTRL_C), 7 => {
                    cancelled = true;
                    break;
                },
                @intFromEnum(KeyCode.BACKSPACE), @intFromEnum(KeyCode.CTRL_H) => try self.editBackspace(),
                else => try self.editInputByte(byte, false),
            }
        }

        self.active_prompt = normal_prompt;
        if (cancelled) {
            try self.replaceBuffer(original.line, original.point);
            self.history_index = original.history_index;
            try self.refreshLine();
            return;
        }

        if (self.buf.items.len > 0) {
            self.last_search.clearRetainingCapacity();
            try self.last_search.appendSlice(self.gpa, self.buf.items);
        }
        const start = switch (direction) {
            .backward => if (original.history_index == 0) null else @min(original.history_index, history.len()) - 1,
            .forward => if (original.history_index + 1 < history.len())
                original.history_index + 1
            else
                null,
        };
        const match = if (start) |at|
            history.find(self.last_search.items, at, direction, .substring)
        else
            null;
        if (match) |found| {
            try self.acceptSearchMatch(original, found);
        } else {
            try self.replaceBuffer(original.line, original.point);
            self.history_index = original.history_index;
            try self.cfg.out.writeByte(7);
        }
        try self.refreshLine();
    }

    fn takeEscapeByte(self: *Repl) Io.Reader.Error!?u8 {
        return self.cfg.in.takeByte() catch |err| switch (err) {
            Io.Reader.Error.EndOfStream => null,
            else => return err,
        };
    }

    fn editEscapeSequence(self: *Repl) !LastCommand {
        const introducer = (try self.takeEscapeByte()) orelse return .other;

        switch (introducer) {
            '[' => {
                try self.editCsiSequence();
                return .other;
            },
            'O' => {
                const final = (try self.takeEscapeByte()) orelse return .other;
                try self.editEscapeFinal(final, null);
                return .other;
            },
            'b', 'B' => {
                try self.editBackwardWord();
                return .other;
            },
            'f', 'F' => {
                try self.editForwardWord();
                return .other;
            },
            'p', 'P' => {
                try self.editNonIncrementalSearch(.backward);
                return .other;
            },
            'n', 'N' => {
                try self.editNonIncrementalSearch(.forward);
                return .other;
            },
            'y', 'Y' => return self.editYankPop(),
            else => return .other,
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
            'A' => try self.editPreviousHistory(),
            'B' => try self.editNextHistory(),
            'C' => try self.editMoveRight(),
            'D' => try self.editMoveLeft(),
            'H' => try self.editStartOfLine(),
            'F' => try self.editEndOfLine(),
            '~' => switch (parameter orelse return) {
                1, 7 => try self.editStartOfLine(),
                3 => try self.editDelete(),
                4, 8 => try self.editEndOfLine(),
                200 => try self.editBracketedPaste(),
                else => {},
            },
            else => {},
        }
    }

    fn editBracketedPaste(self: *Repl) !void {
        const suffix = "\x1b[201~";
        var pasted: std.ArrayList(u8) = .empty;
        defer pasted.deinit(self.gpa);

        while (true) {
            var byte = try self.cfg.in.takeByte();
            if (byte == '\r') byte = '\n';
            try pasted.append(self.gpa, byte);

            if (pasted.items.len >= suffix.len and std.mem.endsWith(u8, pasted.items, suffix)) {
                pasted.items.len -= suffix.len;
                break;
            }
        }

        try self.editInsertSlice(pasted.items);
    }

    fn refreshLine(self: *Repl) !void {
        if (self.cfg.columns == null or self.cfg.rows == null) {
            const current_size = terminal.size();
            if (self.cfg.columns == null) self.cols = current_size.columns;
            if (self.cfg.rows == null) self.rows = current_size.rows;
        }
        var next = try display.layout(
            self.gpa,
            self.active_prompt,
            self.buf.items,
            self.pos,
            self.cols,
        );
        defer next.deinit(self.gpa);

        const visible_rows = @min(next.rows.items.len, @max(self.rows, 1));
        var first_row: usize = 0;
        if (next.cursor_row >= visible_rows) {
            first_row = next.cursor_row - visible_rows + 1;
        }
        if (first_row + visible_rows > next.rows.items.len) {
            first_row = next.rows.items.len - visible_rows;
        }
        const cursor_row = next.cursor_row - first_row;

        if (self.rendered_rows > 0) {
            try self.cfg.out.writeAll("\r");
            if (self.rendered_cursor_row > 0) {
                try self.cfg.out.print("\x1b[{d}A", .{self.rendered_cursor_row});
            }
        }

        const paint_rows = @max(self.rendered_rows, visible_rows);
        for (0..paint_rows) |row| {
            if (row < visible_rows) try self.cfg.out.writeAll(next.row(first_row + row));
            try self.cfg.out.writeAll("\x1b[0K");
            if (row + 1 < paint_rows) try self.cfg.out.writeAll("\r\n");
        }

        const bottom_row = paint_rows - 1;
        if (bottom_row > cursor_row) {
            try self.cfg.out.print("\x1b[{d}A", .{bottom_row - cursor_row});
        }
        try self.cfg.out.writeAll("\r");
        if (next.cursor_col > 0) {
            try self.cfg.out.print("\x1b[{d}C", .{next.cursor_col});
        }
        try self.cfg.out.flush();

        self.rendered_rows = visible_rows;
        self.rendered_cursor_row = cursor_row;
    }

    fn finishAtBottom(self: *Repl) !void {
        // If point is in an earlier viewport, display the final viewport before
        // handing control back to the caller. This leaves subsequent output
        // below the complete accepted or cancelled input.
        if (self.pos != self.buf.items.len) {
            const saved_pos = self.pos;
            self.pos = self.buf.items.len;
            defer self.pos = saved_pos;
            try self.refreshLine();
        }
        if (self.rendered_rows > 0) {
            const bottom_row = self.rendered_rows - 1;
            if (bottom_row > self.rendered_cursor_row) {
                try self.cfg.out.print("\x1b[{d}B", .{bottom_row - self.rendered_cursor_row});
            }
            try self.cfg.out.writeAll("\r");
            self.rendered_cursor_row = bottom_row;
        }
        try self.disableBracketedPaste();
        try self.cfg.out.flush();
    }

    fn disableBracketedPaste(self: *Repl) !void {
        if (!self.bracketed_paste_enabled) return;
        try self.cfg.out.writeAll("\x1b[?2004l");
        self.bracketed_paste_enabled = false;
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
    const ctrl_j = "\x0a";
    const ctrl_v = "\x16";
    const paste_begin = "\x1b[200~";
    const paste_end = "\x1b[201~";
    const backspace = "\x7f";
    const ctrl_c = "\x03";
    const ctrl_d = "\x04";
    const ctrl_f = "\x06";
    const ctrl_n = "\x0e";
    const ctrl_p = "\x10";
    const ctrl_r = "\x12";
    const ctrl_s = "\x13";
    const ctrl_y = "\x19";
    const left = "\x1b[D";
    const up = "\x1b[A";
    const down = "\x1b[B";
    const home = "\x1b[H";
    const end = "\x1b[F";
    const meta_b = "\x1bb";
    const meta_f = "\x1bf";
    const meta_y = "\x1by";
    const meta_p = "\x1bp";
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

test "setPrompt and readlinePrompt change the prompt for later lines" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("one" ++ testKeys.enter ++ "two" ++ testKeys.enter ++ "three" ++ testKeys.enter);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "db> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("one", try repl.readline());
    repl.setPrompt("db2-> ");
    try std.testing.expectEqualStrings("two", try repl.readline());
    try std.testing.expectEqualStrings("three", try repl.readlinePrompt("-> "));

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "db> one") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "db2-> two") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "-> three") != null);
}

test "kitty fallback prompt is chosen once and used for every line" {
    const allocator = std.testing.allocator;
    // A device-attributes reply without the Kitty OK means no graphics support.
    var input: Io.Reader = .fixed("\x1b[?1;2c" ++ "a" ++ testKeys.enter ++ "b" ++ testKeys.enter);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const setup = "\x1b_Ga=p,U=1,i=42,c=1,r=1,q=2\x1b\\";
    const cfg: ReplConfig = .{
        .prompt = "\x01" ++ setup ++ "\x02> ",
        .fallback_prompt = "$ ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
        .rows = 24,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("a", try repl.readline());
    try std.testing.expectEqualStrings("b", try repl.readline());
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, output.written(), setup));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "$ b") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "a=q,t=d"));
}

test "kitty prompt setup is emitted only once while placeholders repaint" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("a" ++ testKeys.enter);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const setup = "\x1b_Ga=p,U=1,i=42,c=1,r=1,q=2\x1b\\";
    const cfg: ReplConfig = .{
        .prompt = "\x01" ++ setup ++ "\x02\u{10eeee}\u{0305}> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
        .rows = 24,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("a", try repl.readline());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), setup));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), "\u{10eeee}"));
}

test "kitty capability responses are recognized before device attributes" {
    var ok_response: [128]u8 = undefined;
    const ok = try std.fmt.bufPrint(
        &ok_response,
        "\x1b_Gi={d};OK\x1b\\\x1b[?1;2c",
        .{Repl.kitty_query_id},
    );
    try std.testing.expect(Repl.hasKittyOkResponse(ok));
    try std.testing.expect(Repl.hasDeviceAttributesResponse(ok));

    var error_response: [128]u8 = undefined;
    const unsupported = try std.fmt.bufPrint(
        &error_response,
        "\x1b_Gi={d};EINVAL\x1b\\\x1b[?1;2c",
        .{Repl.kitty_query_id},
    );
    try std.testing.expect(!Repl.hasKittyOkResponse(unsupported));
    try std.testing.expect(Repl.hasDeviceAttributesResponse(unsupported));
}

test "quoted ctrl-j inserts a literal newline" {
    try expectReadline(
        "first" ++ testKeys.ctrl_v ++ testKeys.ctrl_j ++ "second" ++ testKeys.enter,
        80,
        "first\nsecond",
    );
}

test "bracketed paste inserts newlines and controls without executing them" {
    try expectReadline(
        "before" ++ testKeys.paste_begin ++ "first\rsecond\x03" ++ testKeys.paste_end ++
            "after" ++ testKeys.enter,
        80,
        "beforefirst\nsecond\x03after",
    );
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

test "history navigation preserves edits and the unfinished line" {
    const allocator = std.testing.allocator;
    var history = History.init(allocator, .{});
    defer history.deinit();
    _ = try history.add("old", 1);
    _ = try history.add("new", 2);

    var input: Io.Reader = .fixed(
        "unfinished" ++ testKeys.ctrl_p ++ "!" ++ testKeys.up ++
            testKeys.ctrl_n ++ testKeys.down ++ testKeys.enter,
    );
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
        .history = &history,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("unfinished", try repl.readline());
    try std.testing.expectEqualStrings("new!", history.get(1).?.line);
}

test "incremental search changes direction and accepts a match" {
    const allocator = std.testing.allocator;
    var history = History.init(allocator, .{});
    defer history.deinit();
    _ = try history.add("git status", 1);
    _ = try history.add("zig build", 2);
    _ = try history.add("git diff", 3);

    var input: Io.Reader = .fixed(
        testKeys.ctrl_r ++ "git" ++ testKeys.ctrl_r ++ testKeys.ctrl_s ++ testKeys.enter,
    );
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
        .history = &history,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("git diff", try repl.readline());
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "reverse-i-search") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "forward-i-search") != null);
}

test "ctrl-e accepts an incremental search match and moves to its end" {
    const allocator = std.testing.allocator;
    var history = History.init(allocator, .{});
    defer history.deinit();
    _ = try history.add("echo matching command", 1);

    var input: Io.Reader = .fixed(testKeys.ctrl_r ++ "matching" ++ "\x05" ++ "!" ++ testKeys.enter);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
        .history = &history,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("echo matching command!", try repl.readline());
}

test "meta-p performs a prompted non-incremental history search" {
    const allocator = std.testing.allocator;
    var history = History.init(allocator, .{});
    defer history.deinit();
    _ = try history.add("git status", 1);
    _ = try history.add("zig build", 2);

    var input: Io.Reader = .fixed(testKeys.meta_p ++ "build" ++ testKeys.enter ++ testKeys.enter);
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 80,
        .history = &history,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();

    try std.testing.expectEqualStrings("zig build", try repl.readline());
}

test "yank pop replaces differently sized kills without removing following text" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed(
        "leftright" ++ testKeys.home ++ testKeys.ctrl_f ++ testKeys.ctrl_f ++
            testKeys.ctrl_f ++ testKeys.ctrl_f ++ testKeys.ctrl_y ++
            testKeys.meta_y ++ testKeys.meta_y ++ testKeys.enter,
    );
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

    try repl.kills.push("medium", 0, 6, false);
    try repl.kills.push("x", 0, 1, false);
    try repl.kills.push("most-recent", 0, 11, false);

    try std.testing.expectEqualStrings("leftmediumright", try repl.readline());
}

test "meta-b and meta-f move by Readline words" {
    try expectReadline(
        "one two.three" ++ testKeys.meta_b ++ testKeys.meta_b ++ "-" ++
            testKeys.meta_f ++ "!" ++ testKeys.enter,
        80,
        "one -two!.three",
    );
}

test "meta-b and meta-f respect UTF-8 boundaries" {
    try expectReadline(
        "é界 ok" ++ testKeys.meta_b ++ testKeys.meta_b ++ "!" ++
            testKeys.meta_f ++ "?" ++ testKeys.enter,
        80,
        "!é界? ok",
    );
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
    try std.testing.expectEqualStrings("> aéz\x1b[0K\r\x1b[4C", output.written());
}

test "redisplay clears physical rows left after reflow" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("");
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 4,
        .rows = 24,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();
    repl.cols = 4;
    repl.rows = 24;
    try repl.buf.appendSlice(allocator, "abcdef");
    repl.pos = repl.buf.items.len;
    try repl.refreshLine();

    output.writer.end = 0;
    repl.buf.items.len = 1;
    repl.pos = 1;
    try repl.refreshLine();

    try std.testing.expectEqualStrings(
        "\r\x1b[2A> a\x1b[0K\r\n\x1b[0K\r\n\x1b[0K\x1b[2A\r\x1b[3C",
        output.written(),
    );
}

test "redisplay keeps the cursor visible when input exceeds terminal height" {
    const allocator = std.testing.allocator;
    var input: Io.Reader = .fixed("");
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const cfg: ReplConfig = .{
        .prompt = "> ",
        .in = &input,
        .out = &output.writer,
        .columns = 4,
        .rows = 2,
    };
    var repl = try Repl.init(allocator, &cfg);
    defer repl.deinit();
    repl.cols = 4;
    repl.rows = 2;
    try repl.buf.appendSlice(allocator, "abcdef");
    repl.pos = repl.buf.items.len;

    try repl.refreshLine();

    try std.testing.expectEqual(@as(usize, 2), repl.rendered_rows);
    try std.testing.expectEqual(@as(usize, 1), repl.rendered_cursor_row);
    try std.testing.expectEqualStrings("cdef\x1b[0K\r\n\x1b[0K\r", output.written());
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
