//! Client state shared by the REPL and batch input: the pager, the tee file,
//! and the warnings switch. Output goes through `Mirror`, which copies it to
//! the tee file, and through `ResultSink`, which sends result sets to the pager.
//! The commands that change this state live here too, with `status`, and `yank`
//! copies the last result set kept for it.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mysql = @import("mysql.zig");
const Options = @import("options.zig");
const Clipboard = @import("clipboard.zig");
const Prompt = @import("prompt.zig");

const tee_buffer_len = 4096;

allocator: Allocator,
io: std.Io,
/// Stdout without the tee copy. Result sets go here, or to the pager.
stdout: *std.Io.Writer,
/// Batch input has no pager and no tee file, as in mysql.cc.
batch: bool,
show_warnings: bool = false,
/// Shell command that result sets are piped through, or null to print to stdout. Owned.
pager: ?[]u8 = null,
/// What `pager` uses with no argument. Owned.
default_pager: ?[]u8 = null,
/// The last tee file name. `tee` with no argument reopens it. Owned.
outfile: ?[]u8 = null,
/// The open tee file. Everything written through a `Mirror` is also written here.
tee: ?Tee = null,
/// The format `yank` uses with no argument, from --clipboard-format.
clipboard_format: Options.ResultFormat = .tab,
/// Largest result set that `yank` keeps, from --clipboard-max-bytes. 0 keeps none.
clipboard_max_bytes: u64 = 64 * 1024 * 1024,
/// The backend settings `yank` copies with.
clipboard: Clipboard.Config = .{},
/// The last result set of the REPL, kept for `yank`. Owned until the next result set or `deinit`.
last_result: ?Kept = null,
/// True when the last result set was over clipboard-max-bytes, so it was not kept.
last_too_large: bool = false,

const Tee = struct {
    file: std.Io.File,
    writer: std.Io.File.Writer,
};

const Kept = struct {
    result: Mysql.Result,
    rows: u64,
    /// The field bytes of every row, as counted by `Mysql.countFieldBytes`.
    bytes: u64,
};

pub fn init(allocator: Allocator, io: std.Io, stdout: *std.Io.Writer, batch: bool) Client {
    return .{ .allocator = allocator, .io = io, .stdout = stdout, .batch = batch };
}

pub fn deinit(self: *Client) void {
    self.dropLastResult();
    self.closeTee();
    if (self.pager) |text| self.allocator.free(text);
    if (self.default_pager) |text| self.allocator.free(text);
    if (self.outfile) |text| self.allocator.free(text);
}

fn replaceOwned(self: *Client, field: *?[]u8, value: ?[]const u8) !void {
    const copy = if (value) |text| try self.allocator.dupe(u8, text) else null;
    if (field.*) |old| self.allocator.free(old);
    field.* = copy;
}

/// Sets the startup pager. `--pager` with no value, or an empty one, uses $PAGER.
/// The same default is what `pager` uses with no argument. Without `--pager`,
/// results are not paged.
pub fn configurePager(self: *Client, option: ?[]const u8, env_pager: ?[]const u8) !void {
    const env_value = nonEmpty(env_pager);
    const default = if (option) |text| (nonEmpty(text) orelse env_value) else env_value;
    try self.replaceOwned(&self.default_pager, default);
    if (option != null) {
        try self.replaceOwned(&self.pager, default);
    }
}

fn nonEmpty(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len == 0) null else value;
}

/// The writer for the tee file, or null when no tee file is open.
pub fn teeWriter(self: *Client) ?*std.Io.Writer {
    if (self.tee) |*tee| {
        return &tee.writer.interface;
    }
    return null;
}

/// Copies one line of typed input to the tee file, with its prompt, as mysql.cc does. The
/// prompt is copied without colour codes, so the file has plain text.
pub fn echoInput(self: *Client, prompt: []const u8, line: []const u8) void {
    const tee = self.teeWriter() orelse return;
    Prompt.writeWithoutCsi(tee, prompt) catch {};
    tee.writeAll(line) catch {};
    tee.writeAll("\n") catch {};
}

fn closeTee(self: *Client) void {
    if (self.tee) |*tee| {
        tee.writer.interface.flush() catch {};
        tee.file.close(self.io);
        self.allocator.free(tee.writer.interface.buffer);
        self.tee = null;
    }
}

/// `tee [file]`. Without a file, it reopens the last one, as in mysql.cc.
pub fn cmdTee(self: *Client, out: *std.Io.Writer, arg: []const u8) !void {
    if (self.batch) {
        return;
    }
    if (arg.len > 0) {
        return self.openTee(out, arg);
    }
    const previous = self.outfile orelse {
        try out.print("No previous outfile available, you must give a filename!\n", .{});
        return;
    };
    if (self.tee != null) {
        try out.print("Currently logging to file '{s}'\n", .{previous});
        return;
    }
    return self.openTee(out, previous);
}

fn openTee(self: *Client, out: *std.Io.Writer, path: []const u8) !void {
    self.closeTee();
    var file = std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = false }) catch {
        try out.print("Error logging to file '{s}'\n", .{path});
        return;
    };
    errdefer file.close(self.io);

    // Appending: start writing at the current end of the file.
    const buffer = try self.allocator.alloc(u8, tee_buffer_len);
    errdefer self.allocator.free(buffer);
    var writer = file.writer(self.io, buffer);
    writer.pos = file.length(self.io) catch 0;

    try self.replaceOwned(&self.outfile, path);
    // mysql.cc prints this before the tee starts, so the message stays off the file.
    try out.print("Logging to file '{s}'\n", .{path});
    self.tee = .{ .file = file, .writer = writer };
}

/// `notee`: stops copying output to the tee file.
pub fn cmdNotee(self: *Client, out: *std.Io.Writer) !void {
    self.closeTee();
    try out.print("Outfile disabled.\n", .{});
}

/// `pager [command]`: sets the command that result sets go through.
pub fn cmdPager(self: *Client, out: *std.Io.Writer, arg: []const u8) !void {
    if (self.batch) {
        return;
    }
    if (arg.len == 0) {
        const default = self.default_pager orelse {
            try out.print("Default pager wasn't set, using stdout.\n", .{});
            try self.replaceOwned(&self.pager, null);
            return;
        };
        try self.replaceOwned(&self.pager, default);
    } else {
        try self.replaceOwned(&self.default_pager, arg);
        try self.replaceOwned(&self.pager, arg);
    }
    try out.print("PAGER set to '{s}'\n", .{self.pager.?});
}

/// `nopager`: prints result sets to stdout.
pub fn cmdNopager(self: *Client, out: *std.Io.Writer) !void {
    try self.replaceOwned(&self.pager, null);
    try out.print("PAGER set to stdout\n", .{});
}

/// Sets the `yank` settings from the options. `env` is read for the clipboard backend.
pub fn configureClipboard(self: *Client, options: *const Options.Options, env: *const std.process.Environ.Map) void {
    self.clipboard_format = options.clipboard_format;
    self.clipboard_max_bytes = options.clipboard_max_bytes;
    self.clipboard = .{
        .command = options.clipboard_command,
        .osc52_max_bytes = options.osc52_max_bytes,
        .env = env,
    };
}

/// Decides whether `yank` keeps a result set that is about to be rendered. The one kept before
/// is freed, so only the last result set is kept. Returns true when the client now owns `result`,
/// so the caller must not free it. A result over clipboard-max-bytes is not kept.
pub fn keepResult(self: *Client, result: Mysql.Result) bool {
    self.dropLastResult();
    if (self.clipboard_max_bytes == 0) {
        return false;
    }
    const bytes = Mysql.countFieldBytes(result);
    if (bytes > self.clipboard_max_bytes) {
        self.last_too_large = true;
        return false;
    }
    self.last_result = .{ .result = result, .rows = Mysql.resultRows(result), .bytes = bytes };
    return true;
}

fn dropLastResult(self: *Client) void {
    self.last_too_large = false;
    if (self.last_result) |kept| {
        Mysql.freeResult(kept.result);
        self.last_result = null;
    }
}

/// `yank [format]`: copies the last result set to the clipboard, in `arg` or the clipboard format.
/// Batch input has no clipboard, as it has no pager or tee file.
pub fn cmdYank(self: *Client, out: *std.Io.Writer, arg: []const u8) !void {
    if (self.batch) {
        return;
    }
    if (self.clipboard_max_bytes == 0) {
        try out.print("Clipboard copy is off, because clipboard-max-bytes is 0.\n", .{});
        return;
    }
    var format = self.clipboard_format;
    if (arg.len > 0) {
        format = std.meta.stringToEnum(Options.ResultFormat, arg) orelse {
            try out.print("Invalid result format '{s}'. Expected table, tab, vertical, json, ndjson, or csv.\n", .{arg});
            return;
        };
    }
    const kept = self.last_result orelse {
        if (self.last_too_large) {
            try out.print("The last result set is over clipboard-max-bytes, so it was not kept.\n", .{});
        } else {
            try out.print("No result set to copy.\n", .{});
        }
        return;
    };

    var text: std.Io.Writer.Allocating = .init(self.allocator);
    defer text.deinit();
    Mysql.rewindResult(kept.result);
    try Mysql.renderResultAs(&text.writer, kept.result, format, .{
        .allocator = self.allocator,
        .raw = true,
        .pretty = format == .json,
    });
    const bytes = text.written();

    switch (try Clipboard.copy(self.io, self.clipboard, self.stdout, bytes)) {
        .copied => {
            try out.print("Copied {d} rows as {s} to the clipboard (", .{ kept.rows, @tagName(format) });
            try writeSize(out, bytes.len);
            try out.print(").\n", .{});
        },
        .too_large => try out.print(
            "Not copied: {d} bytes is more than osc52-max-bytes ({d}). Set clipboard-command to copy it.\n",
            .{ bytes.len, self.clipboard.osc52_max_bytes },
        ),
        .failed => |backend| try out.print("Copy with {s} failed.\n", .{backend.name()}),
    }
}

/// Writes a size for the copy message: bytes below 1 KB, else KB or MB to one decimal place.
fn writeSize(out: *std.Io.Writer, bytes: usize) !void {
    const kib = 1024;
    if (bytes < kib) {
        try out.print("{d} bytes", .{bytes});
    } else if (bytes < kib * kib) {
        try out.print("{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / kib});
    } else {
        try out.print("{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (kib * kib)});
    }
}

/// `warnings` and `nowarning`: turn the warnings shown after each statement on or off.
pub fn cmdWarnings(self: *Client, out: *std.Io.Writer, on: bool) !void {
    self.show_warnings = on;
    try out.print("Show warnings {s}.\n", .{if (on) "enabled" else "disabled"});
}

/// Shows the warnings of a statement that just ran, when warnings are on.
/// `error_code` is the statement's error, or 0. As in mysql.cc, warnings also show after an error.
pub fn afterStatement(self: *Client, db: *Mysql.DB, out: *std.Io.Writer, warnings: u32, error_code: u32) !void {
    if (!self.show_warnings) {
        return;
    }
    if (warnings == 0 and error_code == 0) {
        return;
    }
    try db.renderWarnings(out, error_code);
}

/// `print`: prints the statement in progress, framed by lines, as mysql.cc's print_query.
pub fn renderPrint(out: *std.Io.Writer, sql: []const u8) !void {
    try out.print("--------------\n", .{});
    try out.writeAll(sql);
    if (sql.len == 0 or sql[sql.len - 1] != '\n') {
        try out.writeAll("\n");
    }
    try out.print("--------------\n\n", .{});
}

/// Writes to `primary`, and also to the tee file when one is open.
pub const Mirror = struct {
    interface: std.Io.Writer,
    primary: *std.Io.Writer,
    client: *Client,

    pub fn init(primary: *std.Io.Writer, client: *Client) Mirror {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = &.{} },
            .primary = primary,
            .client = client,
        };
    }

    pub fn writer(self: *Mirror) *std.Io.Writer {
        return &self.interface;
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Mirror = @alignCast(@fieldParentPtr("interface", w));
        var consumed: usize = 0;
        for (data, 0..) |bytes, index| {
            const repeat = if (index + 1 == data.len) splat else 1;
            for (0..repeat) |_| {
                try self.primary.writeAll(bytes);
                if (self.client.teeWriter()) |tee| {
                    // Colour is for the terminal only, so the tee file gets the text without it.
                    Prompt.writeWithoutCsi(tee, bytes) catch {};
                }
                consumed += bytes.len;
            }
        }
        return consumed;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Mirror = @alignCast(@fieldParentPtr("interface", w));
        try self.primary.flush();
        if (self.client.teeWriter()) |tee| {
            tee.flush() catch {};
        }
    }
};

/// Output for one result set. With a pager set, the rows go to the pager's
/// stdin. Either way they are copied to the tee file. Open and close one per
/// result set, in place: the writers point into this struct, so it must not move.
pub const ResultSink = struct {
    io: std.Io = undefined,
    child: std.process.Child = undefined,
    piped: bool = false,
    pipe_buffer: [4096]u8 = undefined,
    pipe: std.Io.File.Writer = undefined,
    mirror: Mirror = undefined,

    pub fn open(self: *ResultSink, client: *Client) !void {
        self.io = client.io;
        self.piped = false;
        self.mirror = Mirror.init(client.stdout, client);
        if (client.batch) {
            return;
        }
        const command = client.pager orelse return;

        // Flush first, so text printed before the pager starts stays in order.
        try client.stdout.flush();
        self.child = std.process.spawn(client.io, .{
            .argv = &.{ "/bin/sh", "-c", command },
            .stdin = .pipe,
        }) catch |err| {
            try client.stdout.print("Cannot start pager '{s}': {s}. Printing to stdout.\n", .{ command, @errorName(err) });
            return;
        };
        self.pipe = self.child.stdin.?.writerStreaming(client.io, &self.pipe_buffer);
        self.piped = true;
        self.mirror = Mirror.init(&self.pipe.interface, client);
    }

    pub fn writer(self: *ResultSink) *std.Io.Writer {
        return self.mirror.writer();
    }

    /// True when the rows go to a pager. A pager that exits early makes writes fail.
    pub fn isPiped(self: *const ResultSink) bool {
        return self.piped;
    }

    pub fn close(self: *ResultSink) void {
        if (!self.piped) {
            return;
        }
        self.piped = false;
        self.pipe.interface.flush() catch {};
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
        }
        self.child.stdin = null;
        _ = self.child.wait(self.io) catch {};
    }
};

/// Prints the status block of mysql.cc's com_status. `delimiter` is the one in effect.
pub fn renderStatus(self: *Client, db: *Mysql.DB, out: *std.Io.Writer, delimiter: []const u8) !void {
    try out.print("--------------\n", .{});
    try out.print("thysql, client library {s}\n", .{Mysql.clientInfo()});
    try out.print("\nConnection id:\t\t{}\n", .{db.connectionId()});

    if (try db.firstRowCopy(self.allocator, "select DATABASE(), USER() limit 1")) |row| {
        defer Mysql.freeRowCopy(self.allocator, row);
        try out.print("Current database:\t{s}\n", .{cell(row, 0)});
        try out.print("Current user:\t\t{s}\n", .{cell(row, 1)});
    }

    if (db.sslCipher()) |cipher| {
        try out.print("SSL:\t\t\tCipher in use is {s}, cert is {s}\n", .{
            cipher,
            if (db.tls.verify_server_cert) "OK" else "UNKNOWN",
        });
    } else {
        try out.print("SSL:\t\t\tNot in use\n", .{});
    }

    try out.print("Current pager:\t\t{s}\n", .{self.pager orelse "stdout"});
    const outfile = if (self.tee != null) self.outfile orelse "" else "";
    try out.print("Using outfile:\t\t'{s}'\n", .{outfile});
    try out.print("Using delimiter:\t{s}\n", .{delimiter});
    try out.print("Server:\t\t\t{s}\n", .{db.serverName()});

    const version_comment = try db.firstRowCopy(self.allocator, "select @@version_comment limit 1");
    if (version_comment) |row| {
        defer Mysql.freeRowCopy(self.allocator, row);
        const comment = cell(row, 0);
        if (comment.len > 0) {
            try out.print("Server version:\t\t{s} {s}\n", .{ db.serverVersion(), comment });
        } else {
            try out.print("Server version:\t\t{s}\n", .{db.serverVersion()});
        }
    } else {
        try out.print("Server version:\t\t{s}\n", .{db.serverVersion()});
    }

    try out.print("Protocol version:\t{}\n", .{db.protocolVersion()});
    try out.print("Connection:\t\t{s}\n", .{db.hostInfo()});

    const charsets = try db.firstRowCopy(
        self.allocator,
        "select @@character_set_client, @@character_set_connection, @@character_set_server, @@character_set_database limit 1",
    );
    if (charsets) |row| {
        defer Mysql.freeRowCopy(self.allocator, row);
        try out.print("Server characterset:\t{s}\n", .{cell(row, 2)});
        try out.print("Db     characterset:\t{s}\n", .{cell(row, 3)});
        try out.print("Client characterset:\t{s}\n", .{cell(row, 0)});
        try out.print("Conn.  characterset:\t{s}\n", .{cell(row, 1)});
    }

    if (std.mem.indexOf(u8, db.hostInfo(), "TCP/IP") != null or db.socket.len == 0) {
        try out.print("TCP port:\t\t{}\n", .{db.port});
    } else {
        try out.print("UNIX socket:\t\t{s}\n", .{db.socket});
    }

    if (db.statLine()) |stat| {
        if (parseStat(stat)) |parsed| {
            try out.print("{s}\t\t\t", .{parsed.label});
            try writeNiceTime(out, parsed.seconds);
            try out.print("\n{s}\n", .{parsed.rest});
        }
    }
    try out.print("--------------\n\n", .{});
}

fn cell(row: []?[]u8, index: usize) []const u8 {
    return row[index] orelse "";
}

/// The parts of `mysql_stat` output that `status` prints. For "Uptime: 3725  Threads: 2",
/// the label is "Uptime:", the seconds are 3725, and the rest is "Threads: 2".
pub const Stat = struct {
    label: []const u8,
    seconds: u64,
    rest: []const u8,
};

pub fn parseStat(text: []const u8) ?Stat {
    const label_end = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    const after_label = std.mem.trimStart(u8, text[label_end..], " ");
    const number_end = std.mem.indexOfScalar(u8, after_label, ' ') orelse after_label.len;
    const seconds = std.fmt.parseUnsigned(u64, after_label[0..number_end], 10) catch return null;
    return .{
        .label = text[0..label_end],
        .seconds = seconds,
        .rest = std.mem.trimStart(u8, after_label[number_end..], " "),
    };
}

/// Writes seconds as mysql.cc's nice_time does: "1 day 2 hours 3 min 4 sec".
pub fn writeNiceTime(out: *std.Io.Writer, seconds: u64) !void {
    var rest = seconds;
    if (rest >= 86400) {
        const days = rest / 86400;
        rest %= 86400;
        try out.print("{d}{s}", .{ days, if (days > 1) " days " else " day " });
    }
    if (rest >= 3600) {
        const hours = rest / 3600;
        rest %= 3600;
        try out.print("{d}{s}", .{ hours, if (hours > 1) " hours " else " hour " });
    }
    if (rest >= 60) {
        try out.print("{d} min ", .{rest / 60});
        rest %= 60;
    }
    try out.print("{d} sec", .{rest});
}

test "nice time spells out days, hours, and minutes" {
    const cases = [_]struct { seconds: u64, text: []const u8 }{
        .{ .seconds = 0, .text = "0 sec" },
        .{ .seconds = 59, .text = "59 sec" },
        .{ .seconds = 60, .text = "1 min 0 sec" },
        .{ .seconds = 3725, .text = "1 hour 2 min 5 sec" },
        .{ .seconds = 90061, .text = "1 day 1 hour 1 min 1 sec" },
        .{ .seconds = 172800, .text = "2 days 0 sec" },
    };
    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try writeNiceTime(&out, case.seconds);
        try std.testing.expectEqualStrings(case.text, out.buffered());
    }
}

test "stat line splits into label, uptime, and the rest" {
    const parsed = parseStat("Uptime: 3725  Threads: 2  Questions: 10  Slow queries: 0").?;
    try std.testing.expectEqualStrings("Uptime:", parsed.label);
    try std.testing.expectEqual(@as(u64, 3725), parsed.seconds);
    try std.testing.expectEqualStrings("Threads: 2  Questions: 10  Slow queries: 0", parsed.rest);

    try std.testing.expect(parseStat("no numbers here") == null);
}

test "copy size is in bytes, KB or MB" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try writeSize(&out, 512);
    try out.writeAll(", ");
    try writeSize(&out, 1229);
    try out.writeAll(", ");
    try writeSize(&out, 3 * 1024 * 1024 / 2);
    try std.testing.expectEqualStrings("512 bytes, 1.2 KB, 1.5 MB", out.buffered());
}

test "print frames the statement and always ends with a newline" {
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try renderPrint(&out, "select 1");
    try std.testing.expectEqualStrings("--------------\nselect 1\n--------------\n\n", out.buffered());

    var empty_buffer: [64]u8 = undefined;
    var empty: std.Io.Writer = .fixed(&empty_buffer);
    try renderPrint(&empty, "");
    try std.testing.expectEqualStrings("--------------\n\n--------------\n\n", empty.buffered());
}

test "pager default comes from the option or $PAGER and only the option enables it" {
    var stdout_buffer: [64]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buffer);
    var client = Client.init(std.testing.allocator, std.testing.io, &stdout, false);
    defer client.deinit();

    try client.configurePager(null, "less");
    try std.testing.expect(client.pager == null);
    try std.testing.expectEqualStrings("less", client.default_pager.?);

    try client.configurePager("", "more");
    try std.testing.expectEqualStrings("more", client.pager.?);

    try client.configurePager("cat", "more");
    try std.testing.expectEqualStrings("cat", client.pager.?);
    try std.testing.expectEqualStrings("cat", client.default_pager.?);
}

test "mirror writes to the primary writer and appends to the tee file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The file is opened relative to the working directory, so use the temp dir's path.
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/out.txt", .{&tmp.sub_path});
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "out.txt", .data = "old\n" });

    var primary_buffer: [128]u8 = undefined;
    var primary: std.Io.Writer = .fixed(&primary_buffer);
    var client = Client.init(std.testing.allocator, io, &primary, false);
    defer client.deinit();

    var message_buffer: [128]u8 = undefined;
    var message: std.Io.Writer = .fixed(&message_buffer);
    try client.cmdTee(&message, path);
    try std.testing.expect(std.mem.startsWith(u8, message.buffered(), "Logging to file '"));

    var mirror = Mirror.init(&primary, &client);
    const out = mirror.writer();
    try out.print("row {d}\n", .{1});
    try out.flush();

    try std.testing.expectEqualStrings("row 1\n", primary.buffered());

    try client.cmdNotee(&message);
    try std.testing.expect(client.teeWriter() == null);

    const contents = try std.Io.Dir.readFileAlloc(.cwd(), io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("old\nrow 1\n", contents);
}

test "echoInput copies the prompt to the tee file without colour codes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The file is opened relative to the working directory, so use the temp dir's path.
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/echo.txt", .{&tmp.sub_path});
    defer std.testing.allocator.free(path);

    var primary_buffer: [128]u8 = undefined;
    var primary: std.Io.Writer = .fixed(&primary_buffer);
    var client = Client.init(std.testing.allocator, io, &primary, false);
    defer client.deinit();

    var message_buffer: [128]u8 = undefined;
    var message: std.Io.Writer = .fixed(&message_buffer);
    try client.cmdTee(&message, path);
    client.echoInput("\x1b[31m[main]\x1b[0m app> ", "select 1;");
    try client.cmdNotee(&message);

    const contents = try std.Io.Dir.readFileAlloc(.cwd(), io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("[main] app> select 1;\n", contents);
}
