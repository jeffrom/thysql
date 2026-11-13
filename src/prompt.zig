//! The interactive prompt in a format string, with the escapes of mysql.cc's
//! construct_prompt. The format comes from --prompt, MYSQL_PS1, or the `prompt`
//! command. `writeFormat` is pure: it takes the connection facts and the clock as
//! arguments, so tests can give it fixed values. With no format, the REPL draws
//! its own connection prompt instead (see src/root.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

// The two C calls the prompt needs for local time. The layout of struct tm is the same on
// macOS and glibc for 64-bit targets, which is what this client is built for.
const TimeT = c_long;
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn time(timer: ?*TimeT) TimeT;
extern "c" fn localtime_r(timer: *const TimeT, result: *Tm) ?*Tm;

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The format that `prompt` with no argument returns to when MYSQL_PS1 is not set.
/// This is the text the REPL shows for its built-in prompt.
pub const builtin_format = "\\u@\\h:\\p/\\d> ";

/// The connection facts that escapes print.
pub const Info = struct {
    /// USER(), such as "root@localhost". \U prints all of it, \u only the part before '@'.
    full_user: []const u8 = "",
    /// The library's host info, such as "127.0.0.1 via TCP/IP". \h and \H read the first word.
    host_info: []const u8 = "",
    /// The machine's host name, for \H when the host is localhost.
    hostname: []const u8 = "",
    port: u32 = 0,
    /// The socket path. \p prints its base name when the connection is not TCP.
    socket: []const u8 = "",
    database: []const u8 = "",
    server_name: []const u8 = "",
    server_version: []const u8 = "",
    delimiter: []const u8 = ";",
};

/// A local date and time. `month` is 0 for January and `weekday` is 0 for Sunday.
pub const Clock = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};

/// The local time now.
pub fn clockNow() Clock {
    var now: TimeT = time(null);
    var parts: Tm = undefined;
    _ = localtime_r(&now, &parts);
    return .{
        .year = parts.tm_year + 1900,
        .month = @intCast(parts.tm_mon),
        .day = @intCast(parts.tm_mday),
        .hour = @intCast(parts.tm_hour),
        .minute = @intCast(parts.tm_min),
        .second = @intCast(parts.tm_sec),
        .weekday = @intCast(parts.tm_wday),
    };
}

/// Renders `format` to a new string. The counter for \c is advanced in place.
pub fn render(allocator: Allocator, format: []const u8, info: Info, counter: *u32, clock: Clock) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeFormat(&out.writer, format, info, counter, clock);
    return out.toOwnedSliceSentinel(0);
}

/// Writes `format` with each escape replaced, as mysql.cc does. A backslash at the
/// end is dropped, and an unknown escape writes its character.
pub fn writeFormat(out: *std.Io.Writer, format: []const u8, info: Info, counter: *u32, clock: Clock) !void {
    var index: usize = 0;
    while (index < format.len) : (index += 1) {
        const byte = format[index];
        if (byte != '\\') {
            try out.writeByte(byte);
            continue;
        }
        index += 1;
        if (index >= format.len) {
            break;
        }
        switch (format[index]) {
            'c' => {
                counter.* += 1;
                try out.print("{d}", .{counter.*});
            },
            'v' => try out.writeAll(info.server_version),
            'd' => try out.writeAll(if (info.database.len == 0) "(none)" else info.database),
            'N' => try out.writeAll(info.server_name),
            'h' => try writeHost(out, info, false),
            'H' => try writeHost(out, info, true),
            'p' => try writePort(out, info),
            'U' => try out.writeAll(nonEmptyOr(info.full_user, "(unknown)")),
            'u' => {
                const full = nonEmptyOr(info.full_user, "(unknown)");
                const at = std.mem.indexOfScalar(u8, full, '@') orelse full.len;
                try out.writeAll(full[0..at]);
            },
            '\\' => try out.writeByte('\\'),
            'n' => try out.writeByte('\n'),
            ' ', '_' => try out.writeByte(' '),
            'S' => try out.writeByte(';'),
            't' => try out.writeByte('\t'),
            '\'' => try out.writeByte('\''),
            '"' => try out.writeByte('"'),
            'l' => try out.writeAll(info.delimiter),
            'R' => try out.print("{d:0>2}", .{clock.hour}),
            'r' => try out.print("{d:0>2}", .{hour12(clock.hour)}),
            'm' => try out.print("{d:0>2}", .{clock.minute}),
            's' => try out.print("{d:0>2}", .{clock.second}),
            'y' => {
                const two_digits: u32 = @intCast(@mod(clock.year, 100));
                try out.print("{d:0>2}", .{two_digits});
            },
            'Y' => try out.print("{d}", .{clock.year}),
            'P' => try out.writeAll(if (clock.hour < 12) "am" else "pm"),
            'w' => try out.writeAll(day_names[clock.weekday]),
            'o' => try out.print("{d}", .{clock.month + 1}),
            'O' => try out.writeAll(month_names[clock.month]),
            // ctime's layout, which mysql.cc uses for \D: "Thu Nov  5 20:05:09 2026".
            'D' => try out.print("{s} {s}{d: >3} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
                day_names[clock.weekday],
                month_names[clock.month],
                clock.day,
                clock.hour,
                clock.minute,
                clock.second,
                clock.year,
            }),
            else => |other| try out.writeByte(other),
        }
    }
}

fn nonEmptyOr(text: []const u8, fallback: []const u8) []const u8 {
    return if (text.len == 0) fallback else text;
}

fn hour12(hour: u8) u8 {
    const value = hour % 12;
    return if (value == 0) 12 else value;
}

/// \h and \H. For localhost, \h prints "localhost" and \H prints the machine name. For
/// anything else, it is the first word of the host info, as in mysql.cc.
fn writeHost(out: *std.Io.Writer, info: Info, full_name: bool) !void {
    const is_localhost = std.mem.indexOf(u8, info.host_info, "Localhost") != null or
        std.mem.indexOf(u8, info.host_info, "localhost ") != null;
    if (is_localhost) {
        try out.writeAll(if (full_name) info.hostname else "localhost");
        return;
    }
    const end = std.mem.indexOfScalar(u8, info.host_info, ' ') orelse info.host_info.len;
    try out.writeAll(info.host_info[0..end]);
}

/// \p prints the port for TCP, and the socket's base name otherwise.
fn writePort(out: *std.Io.Writer, info: Info) !void {
    const is_tcp = std.mem.indexOf(u8, info.host_info, "TCP/IP") != null;
    if (is_tcp or info.socket.len == 0) {
        try out.print("{d}", .{info.port});
        return;
    }
    const slash = std.mem.lastIndexOfScalar(u8, info.socket, '/');
    try out.writeAll(if (slash) |index| info.socket[index + 1 ..] else info.socket);
}

/// The prompt in use. `format` is the one set by --prompt or `prompt`, and
/// `default_format` is MYSQL_PS1. Both are owned copies. With neither, the REPL
/// draws its built-in connection prompt.
pub const State = struct {
    allocator: Allocator,
    default_format: ?[]u8 = null,
    format: ?[]u8 = null,
    /// The \c counter. `prompt` resets it, as mysql.cc does.
    counter: u32 = 0,

    pub fn init(allocator: Allocator, env_default: ?[]const u8, option: ?[]const u8) !State {
        var state: State = .{ .allocator = allocator };
        errdefer state.deinit();
        if (env_default) |text| {
            if (text.len > 0) {
                state.default_format = try allocator.dupe(u8, text);
            }
        }
        if (option) |text| {
            state.format = try allocator.dupe(u8, text);
        }
        return state;
    }

    pub fn deinit(self: *State) void {
        if (self.default_format) |text| self.allocator.free(text);
        if (self.format) |text| self.allocator.free(text);
        self.default_format = null;
        self.format = null;
    }

    /// The format to draw, or null for the built-in connection prompt.
    pub fn activeFormat(self: *const State) ?[]const u8 {
        return self.format orelse self.default_format;
    }

    /// The text that `prompt` shows when it returns to the default.
    pub fn defaultText(self: *const State) []const u8 {
        return self.default_format orelse builtin_format;
    }

    /// Makes `text` the prompt and restarts the \c counter.
    pub fn set(self: *State, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        if (self.format) |old| self.allocator.free(old);
        self.format = copy;
        self.counter = 0;
    }

    /// Returns to the default prompt and restarts the \c counter.
    pub fn reset(self: *State) void {
        if (self.format) |old| self.allocator.free(old);
        self.format = null;
        self.counter = 0;
    }
};

fn testInfo() Info {
    return .{
        .full_user = "root@localhost",
        .host_info = "127.0.0.1 via TCP/IP",
        .hostname = "build-box",
        .port = 3307,
        .socket = "/tmp/mysql.sock",
        .database = "app",
        .server_name = "MariaDB",
        .server_version = "11.4.2-MariaDB",
        .delimiter = ";",
    };
}

fn testClock() Clock {
    // 2026-11-05 20:05:09, a Thursday.
    return .{ .year = 2026, .month = 10, .day = 5, .hour = 20, .minute = 5, .second = 9, .weekday = 4 };
}

fn expectFormat(format: []const u8, info: Info, expected: []const u8) !void {
    var counter: u32 = 0;
    const rendered = try render(std.testing.allocator, format, info, &counter, testClock());
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}

test "user, database, host, port, and server escapes" {
    try expectFormat("\\u@\\U|\\d|\\N|\\v", testInfo(), "root@root@localhost|app|MariaDB|11.4.2-MariaDB");
    try expectFormat("\\h \\H \\p", testInfo(), "127.0.0.1 127.0.0.1 3307");
    try expectFormat("\\d", .{}, "(none)");
    try expectFormat("\\U \\u", .{}, "(unknown) (unknown)");
}

test "localhost prints localhost for \\h and the machine name for \\H" {
    var info = testInfo();
    info.host_info = "Localhost via UNIX socket";
    info.socket = "/tmp/mysql.sock";
    try expectFormat("\\h \\H \\p", info, "localhost build-box mysql.sock");
}

test "time escapes use the given clock, zero-padded where mysql.cc pads" {
    try expectFormat("\\R:\\m:\\s \\r \\P", testInfo(), "20:05:09 08 pm");
    try expectFormat("\\y \\Y \\o \\O \\w", testInfo(), "26 2026 11 Nov Thu");
    try expectFormat("\\D", testInfo(), "Thu Nov  5 20:05:09 2026");
}

test "literal escapes: backslash, space, underscore, delimiter, semicolon, tab, newline" {
    try expectFormat("a\\_b\\\\c\\Sd\\l\\tx\\ny", testInfo(), "a b\\c;d;\tx\ny");
    try expectFormat("it\\'s \\\"q\\\"", testInfo(), "it's \"q\"");
}

test "an unknown escape writes its character, and a trailing backslash is dropped" {
    try expectFormat("\\z\\", testInfo(), "z");
    try expectFormat("x\\", testInfo(), "x");
}

test "\\c counts up across renders" {
    var counter: u32 = 0;
    const first = try render(std.testing.allocator, "[\\c]", testInfo(), &counter, testClock());
    defer std.testing.allocator.free(first);
    const second = try render(std.testing.allocator, "[\\c]", testInfo(), &counter, testClock());
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("[1]", first);
    try std.testing.expectEqualStrings("[2]", second);
}

test "state: the option beats MYSQL_PS1, and reset returns to the default" {
    var state = try State.init(std.testing.allocator, "ps1\\_\\d> ", "--opt> ");
    defer state.deinit();
    try std.testing.expectEqualStrings("--opt> ", state.activeFormat().?);

    state.reset();
    try std.testing.expectEqualStrings("ps1\\_\\d> ", state.activeFormat().?);
    try std.testing.expectEqualStrings("ps1\\_\\d> ", state.defaultText());

    try state.set("new> ");
    try std.testing.expectEqualStrings("new> ", state.activeFormat().?);
    state.reset();
}

test "state: with no option and no MYSQL_PS1, the built-in prompt is used" {
    var state = try State.init(std.testing.allocator, "", null);
    defer state.deinit();
    try std.testing.expect(state.activeFormat() == null);
    try std.testing.expectEqualStrings(builtin_format, state.defaultText());
}

test "state: set restarts the counter" {
    var state = try State.init(std.testing.allocator, null, null);
    defer state.deinit();
    state.counter = 7;
    try state.set("x\\c> ");
    try std.testing.expectEqual(@as(u32, 0), state.counter);
}
