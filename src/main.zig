const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
});
const strippables = " \t";
const patterns = std.StaticStringMap([]const u8).initComptime(.{
    .{ "palette", "4;" },
    .{ "foreground", "10;#" },
    .{ "background", "11;#" },
    .{ "cursor-color", "12;#" },
});
const FALLBACK_TMP = "/tmp";
const LOG_NAME = "/ssh_colouriser.log";
pub const std_options = .{
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime level.asText()[0..3] ++ "] " ++ scope_prefix;
    if (level == std.log.Level.err) {
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
    } else {
        const tmp_dir = std.c.getenv("TMPDIR") orelse FALLBACK_TMP;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        const tmp_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, LOG_NAME }) catch FALLBACK_TMP ++ LOG_NAME;
        if (std.fs.createFileAbsolute(tmp_path, .{ .truncate = false })) |log_file| {
            defer log_file.close();
            if (log_file.seekFromEnd(0)) {
                nosuspend log_file.writer().print(prefix ++ format ++ "\n", args) catch return;
            } else |_| {}
        } else |_| {}
    }
}

pub fn resetScheme() !void {
    const stdout = std.io.getStdOut().writer();
    var counter: u8 = 0;
    while (counter < 15) : (counter += 1) {
        const color_index = [_]u8{'0' + counter};
        try stdout.writeAll("\x1b]104;" ++ &color_index ++ "\x07");
    }
    try stdout.writeAll("\x1b]110\x07");
    try stdout.writeAll("\x1b]111\x07");
    try stdout.writeAll("\x1b]112\x07");
}

fn getThemeName(host_name: []const u8) ![]const u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const proc = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ssh", "-G", host_name },
    });
    defer allocator.free(proc.stdout);
    defer allocator.free(proc.stderr);
    var lines = std.mem.split(u8, proc.stdout, "\n");
    while (lines.next()) |line| {
        var parts = std.mem.split(u8, line, "=");
        const part = std.mem.trim(u8, parts.next() orelse "", strippables);
        if (std.mem.eql(u8, part, "setenv TERMINAL_THEME")) {
            const theme_name = std.mem.trim(u8, parts.next() orelse "", strippables);
            return try allocator.dupeZ(u8, theme_name);
        }
    }
    return "";
}

pub fn setScheme(host_name: []const u8) !void {
    const max_bytes_per_line = 4096;
    const theme_name = try getThemeName(host_name);
    if (theme_name.len > 0) {
        std.log.info("Found theme: {s}", .{theme_name});
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var res_dir = std.process.getEnvVarOwned(allocator, "GHOSTTY_RESOURCES_DIR") catch "";
    if (res_dir.len == 0) {
        res_dir = switch (builtin.os.tag) {
            .macos => "/Applications/Ghostty.app/Contents/Resources/ghostty",
            else => "/usr/share/ghostty",
        };
    }
    const theme_path = std.fmt.allocPrintZ(allocator, "{s}/themes/{s}", .{ res_dir, theme_name }) catch "";
    const theme_file = try std.fs.openFileAbsolute(theme_path, .{});
    defer theme_file.close();
    var buffered_reader = std.io.bufferedReader(theme_file.reader());
    const reader = buffered_reader.reader();
    const stdout = std.io.getStdOut().writer();
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', max_bytes_per_line)) |line| {
        defer allocator.free(line);
        const trimmed = std.mem.trim(u8, line, strippables);
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }
        for (patterns.keys()) |key| {
            if (std.mem.eql(u8, key, trimmed[0..key.len])) {
                var runner = key.len;
                while (trimmed[runner] == ' ' and runner < trimmed.len) {
                    runner += 1;
                }
                if (runner + 2 < trimmed.len and trimmed[runner] == '=' and trimmed[runner + 1] == ' ') {
                    const value = try std.mem.Allocator.dupe(allocator, u8, trimmed[runner + 2 ..]);
                    std.mem.replaceScalar(u8, value, '=', ';');
                    var list = std.ArrayList(u8).init(allocator);
                    defer list.deinit();
                    const pattern_value = patterns.get(key) orelse "";

                    if (pattern_value.len > 0) {
                        // Escape backslashes for logging.
                        try list.appendSlice("\\x1b]");
                        try list.appendSlice(pattern_value);
                        try list.appendSlice(value);
                        try list.appendSlice("\\x07");
                        std.log.info("'{s}': Would use '{s}'", .{ trimmed, list.items });
                        // Now print out the codes for real
                        try stdout.writeAll("\x1b]");
                        try stdout.writeAll(pattern_value);
                        try stdout.writeAll(value);
                        try stdout.writeAll("\x07");
                    }
                } else {
                    continue;
                }
            }
        }
    }
}

fn examineParent() bool {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const ppid = c.getppid();
    const ppid_str = std.fmt.allocPrint(allocator, "{d}", .{ppid}) catch "";
    if (ppid_str.len == 0) {
        return false;
    }
    const argv = [4][]const u8{ "/bin/ps", "-eo", "args=", ppid_str };
    const rr = std.process.Child.run(.{ .allocator = allocator, .argv = &argv }) catch return false;
    std.log.info("Parent command line {s}", .{rr.stdout});
    return true;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Log the current timestamp
    var buffer = try allocator.alloc(u8, 64);
    const t = std.time.timestamp();
    const tmp = c.localtime(&t);
    const count = c.strftime(buffer.ptr, 32, "%Y-%m-%d %H:%M:%S", tmp);
    std.log.info("=== {s}", .{buffer[0..count]});
    allocator.free(buffer);

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    if (args.inner.count != 2) {
        const stderr = std.io.getStdErr().writer();
        _ = try stderr.print("Gimme a single SSH host name to work on!\n", .{});
        return 1;
    }

    // Get parent process information.
    if (examineParent()) {
        // Jump over program name.
        _ = args.next();
        const host_name = args.next();
        if (std.mem.eql(
            u8,
            host_name orelse "",
            "reset",
        )) {
            resetScheme() catch |err| {
                std.log.err("resetScheme failed: {}", .{err});
                return 2;
            };
        } else {
            setScheme(host_name orelse "") catch |err| {
                std.log.err("setScheme failed: {}", .{err});
                return 2;
            };
        }
    }
    return 0;
}
