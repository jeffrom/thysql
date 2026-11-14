//! `thysql completion <shell>`: prints the shell's completion script to stdout. The script calls
//! `thysql complete` for its candidates. Each shell is one embedded file and one entry in `shells`.

const std = @import("std");

const Shell = struct {
    name: []const u8,
    script: []const u8,
};

/// The shells that have a completion script. zsh or fish would be one more file and entry here.
const shells = [_]Shell{
    .{ .name = "bash", .script = @embedFile("completion/thysql.bash") },
};

const usage = "usage: thysql completion bash\n";

/// Runs `thysql completion <shell>`. `args` is the whole argv, with `completion` at args[1].
pub fn run(stdout: *std.Io.Writer, stderr: *std.Io.Writer, args: []const []const u8) !u8 {
    if (args.len != 3) {
        try stderr.writeAll(usage);
        return 1;
    }
    for (shells) |shell| {
        if (std.mem.eql(u8, shell.name, args[2])) {
            try stdout.writeAll(shell.script);
            try stdout.flush();
            return 0;
        }
    }

    try stderr.print("unsupported shell \"{s}\"; supported:", .{args[2]});
    for (shells) |shell| {
        try stderr.print(" {s}", .{shell.name});
    }
    try stderr.writeAll("\n");
    return 1;
}

test "the bash script registers its completer for thysql" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const args = [_][]const u8{ "thysql", "completion", "bash" };
    try std.testing.expectEqual(@as(u8, 0), try run(&out.writer, &stderr, &args));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "complete -F _thysql thysql\n") != null);
    // No -o default on the registration: the script uses the directive, so an empty list stays empty.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "complete -o default") == null);
    try std.testing.expectEqualStrings("", stderr.buffered());
}

test "an unknown shell is an error that names the supported shells" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const args = [_][]const u8{ "thysql", "completion", "zsh" };
    try std.testing.expectEqual(@as(u8, 1), try run(&out.writer, &stderr, &args));
    try std.testing.expectEqualStrings("unsupported shell \"zsh\"; supported: bash\n", stderr.buffered());
    try std.testing.expectEqualStrings("", out.written());
}

test "a missing shell name prints the usage" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var stderr_buffer: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&stderr_buffer);

    const args = [_][]const u8{ "thysql", "completion" };
    try std.testing.expectEqual(@as(u8, 1), try run(&out.writer, &stderr, &args));
    try std.testing.expectEqualStrings(usage, stderr.buffered());
}
