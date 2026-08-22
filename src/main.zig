const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const replete = @import("replete");

var active_term: ?*const replete.TermState = null;

fn handleSigterm(_: posix.SIG) callconv(.c) void {
    if (active_term) |term| term.disable();
    posix.system._exit(128 + @intFromEnum(posix.SIG.TERM));
}

fn installSigtermHandler() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handleSigterm },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.TERM, &action, null);
}

const Options = struct {
    debug: bool = false,
    prompt_image: ?[]const u8 = null,
    prompt_image_id: u8 = 173,
    prompt_columns: usize = 8,
    prompt_rows: usize = 4,
    prompt_gap: usize = 1,
    prompt_text: []const u8 = "> ",
    prompt_fallback: []const u8 = "> ",
    history_enabled: bool = true,
    history_file: ?[]const u8 = null,
    history_limit: usize = 1000,
    history_deduplication: replete.HistoryDeduplication = .consecutive,
    history_timestamps: bool = true,
};

const OptionsError = error{
    MissingOptionValue,
    InvalidOptionValue,
};

fn optionValue(
    args: []const []const u8,
    index: *usize,
    arg: []const u8,
    comptime name: []const u8,
) OptionsError!?[]const u8 {
    if (std.mem.eql(u8, arg, name)) {
        if (index.* + 1 >= args.len) return error.MissingOptionValue;
        index.* += 1;
        return args[index.*];
    }
    if (arg.len > name.len and arg[name.len] == '=' and std.mem.startsWith(u8, arg, name)) {
        return arg[name.len + 1 ..];
    }
    return null;
}

fn parseUnsigned(comptime T: type, value: []const u8) OptionsError!T {
    if (value.len == 0) return error.InvalidOptionValue;
    return std.fmt.parseInt(T, value, 10) catch error.InvalidOptionValue;
}

fn parseOptions(args: []const []const u8) OptionsError!Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--debug")) {
            options.debug = true;
        } else if (std.mem.eql(u8, arg, "--no-history")) {
            options.history_enabled = false;
        } else if (std.mem.eql(u8, arg, "--no-history-timestamps")) {
            options.history_timestamps = false;
        } else if (try optionValue(args, &i, arg, "--history-file")) |value| {
            if (value.len == 0) return error.InvalidOptionValue;
            options.history_file = value;
        } else if (try optionValue(args, &i, arg, "--history-limit")) |value| {
            options.history_limit = try parseUnsigned(usize, value);
        } else if (try optionValue(args, &i, arg, "--history-dedup")) |value| {
            options.history_deduplication = std.meta.stringToEnum(
                replete.HistoryDeduplication,
                value,
            ) orelse return error.InvalidOptionValue;
        } else if (try optionValue(args, &i, arg, "--prompt-image")) |value| {
            if (value.len == 0) return error.InvalidOptionValue;
            options.prompt_image = value;
        } else if (try optionValue(args, &i, arg, "--prompt-image-id")) |value| {
            options.prompt_image_id = try parseUnsigned(u8, value);
            if (options.prompt_image_id == 0) return error.InvalidOptionValue;
        } else if (try optionValue(args, &i, arg, "--prompt-columns")) |value| {
            options.prompt_columns = try parseUnsigned(usize, value);
            if (options.prompt_columns == 0) return error.InvalidOptionValue;
        } else if (try optionValue(args, &i, arg, "--prompt-rows")) |value| {
            options.prompt_rows = try parseUnsigned(usize, value);
            if (options.prompt_rows == 0 or options.prompt_rows > replete.kitty.max_rows) {
                return error.InvalidOptionValue;
            }
        } else if (try optionValue(args, &i, arg, "--prompt-gap")) |value| {
            options.prompt_gap = try parseUnsigned(usize, value);
        } else if (try optionValue(args, &i, arg, "--prompt-text")) |value| {
            options.prompt_text = value;
        } else if (try optionValue(args, &i, arg, "--prompt-fallback")) |value| {
            options.prompt_fallback = value;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    const opts = try parseOptions(args);

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    var history = replete.History.init(init.gpa, .{
        .limit = opts.history_limit,
        .deduplication = opts.history_deduplication,
        .write_timestamps = opts.history_timestamps,
    });
    defer history.deinit();
    const history_path = opts.history_file orelse if (init.environ_map.get("HOME")) |home|
        try std.fmt.allocPrint(arena, "{s}/.replete_history", .{home})
    else
        ".replete_history";
    if (opts.history_enabled) {
        history.readFile(io, history_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    var prompt: []const u8 = opts.prompt_text;
    var fallback_prompt: ?[]const u8 = null;
    if (opts.prompt_image) |path| {
        const png = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
        prompt = try replete.kitty.pngPrompt(arena, png, .{
            .image_id = opts.prompt_image_id,
            .columns = opts.prompt_columns,
            .rows = opts.prompt_rows,
            .gap = opts.prompt_gap,
            .text = opts.prompt_text,
            .alignment = .middle,
        });
        fallback_prompt = opts.prompt_fallback;
    }

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    // need to get stdin's fileno here to put the terminal in raw mode
    // stdin_file_reader.file.handle
    const cfg = replete.ReplConfig{
        .prompt = prompt,
        .fallback_prompt = fallback_prompt,
        .in = stdin_reader,
        .out = stdout_writer,
        .history = if (opts.history_enabled) &history else null,
    };
    var repl = try replete.Repl.init(init.gpa, &cfg);
    defer repl.deinit();

    const term = try replete.TermState.enable(stdin_file_reader.file.handle);
    active_term = &term;
    defer {
        term.disable();
        active_term = null;
    }
    installSigtermHandler();

    if (opts.debug) {
        try repl.debugMode();
    } else {
        while (true) {
            const line = repl.readline() catch |err| switch (err) {
                Io.Reader.Error.EndOfStream => {
                    try stdout_writer.printAscii("\r\n", .{});
                    try stdout_writer.flush();
                    return;
                },
                replete.ReplError.Cancelled => {
                    try stdout_writer.printAscii("\r\n^C\r\n", .{});
                    try stdout_writer.flush();
                    continue;
                },
                else => {
                    try stdout_writer.printAscii("\r\n", .{});
                    try stdout_writer.flush();
                    return err;
                },
            };

            if (line.len > 0) {
                if (opts.history_enabled) {
                    _ = try history.addNow(io, line);
                    try history.writeFile(io, history_path);
                }
                try stdout_writer.print("\r\nreceived line: '{s}'", .{line});
            }
            try stdout_writer.printAscii("\r\n", .{});
            try stdout_writer.flush();
        }
    }
}

// TODO print keys mode

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "prompt image is optional and accepts both flag forms" {
    const plain = try parseOptions(&.{"replete"});
    try std.testing.expect(!plain.debug);
    try std.testing.expectEqual(@as(?[]const u8, null), plain.prompt_image);

    const separate = try parseOptions(&.{ "replete", "--debug", "--prompt-image", "cat.png" });
    try std.testing.expect(separate.debug);
    try std.testing.expectEqualStrings("cat.png", separate.prompt_image.?);

    const joined = try parseOptions(&.{ "replete", "--prompt-image=/tmp/cat.png" });
    try std.testing.expectEqualStrings("/tmp/cat.png", joined.prompt_image.?);

    try std.testing.expectError(error.MissingOptionValue, parseOptions(&.{ "replete", "--prompt-image" }));
}

test "prompt image layout flags parse and validate" {
    const options = try parseOptions(&.{
        "replete",
        "--prompt-image-id=42",
        "--prompt-columns",
        "10",
        "--prompt-rows=5",
        "--prompt-gap",
        "0",
        "--prompt-text=λ> ",
        "--prompt-fallback",
        "$ ",
    });
    try std.testing.expectEqual(@as(u8, 42), options.prompt_image_id);
    try std.testing.expectEqual(@as(usize, 10), options.prompt_columns);
    try std.testing.expectEqual(@as(usize, 5), options.prompt_rows);
    try std.testing.expectEqual(@as(usize, 0), options.prompt_gap);
    try std.testing.expectEqualStrings("λ> ", options.prompt_text);
    try std.testing.expectEqualStrings("$ ", options.prompt_fallback);

    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "replete", "--prompt-image-id=0" }));
    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "replete", "--prompt-columns=nope" }));
    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "replete", "--prompt-rows=0" }));
}

test "history flags parse and validate" {
    const options = try parseOptions(&.{
        "replete",
        "--history-file=/tmp/replete-history",
        "--history-limit",
        "25",
        "--history-dedup=all",
        "--no-history-timestamps",
    });
    try std.testing.expectEqualStrings("/tmp/replete-history", options.history_file.?);
    try std.testing.expectEqual(@as(usize, 25), options.history_limit);
    try std.testing.expectEqual(replete.HistoryDeduplication.all, options.history_deduplication);
    try std.testing.expect(!options.history_timestamps);

    const disabled = try parseOptions(&.{ "replete", "--no-history" });
    try std.testing.expect(!disabled.history_enabled);
    try std.testing.expectError(error.InvalidOptionValue, parseOptions(&.{ "replete", "--history-dedup=adjacent" }));
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
