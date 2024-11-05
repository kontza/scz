const std = @import("std");
const tomlz = @import("tomlz");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/event.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
const strippables = " \t";
const patterns = std.StaticStringMap([]const u8).initComptime(.{
    .{ "palette", "4;" },
    .{ "foreground", "10;#" },
    .{ "background", "11;#" },
    .{ "cursor-color", "12;#" },
});
const FALLBACK_TMP = "/tmp";
const LOG_NAME = "ssh_colouriser.log";
const FALLBACK_LOG = FALLBACK_TMP ++ "/" ++ LOG_NAME;
const MAX_BYTES_PER_LINE = 4096;
const VERSION = "1.0.0";
pub const std_options = .{
    .logFn = myLogFn,
};
pub const log_level: std.log.Level = .debug;

const Config = struct {
    bypasses: []const []const u8,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime level.asText()[0..3] ++ "] " ++ scope_prefix;
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();
    if (level == std.log.Level.err) {
        nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
    } else {
        const tmp_dir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch FALLBACK_TMP;
        defer allocator.free(tmp_dir);
        var tmp_path: []u8 = undefined;
        if (tmp_dir[tmp_dir.len - 1] == '/') {
            tmp_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ tmp_dir, LOG_NAME }) catch "";
        } else {
            tmp_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, LOG_NAME }) catch "";
        }
        defer allocator.free(tmp_path);
        if (std.fs.createFileAbsolute(tmp_path, .{ .truncate = false })) |log_file| {
            defer log_file.close();
            if (log_file.seekFromEnd(0)) {
                nosuspend log_file.writer().print(prefix ++ format ++ "\n", args) catch return;
            } else |e| {
                nosuspend stderr.print("Seek failed: {?}\n", .{e}) catch return;
            }
        } else |e| {
            nosuspend stderr.print("Failed to create log file: {?}\n", .{e}) catch return;
        }
    }
}

pub fn resetScheme() !void {
    std.log.info("Going to reset scheme", .{});
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
    return error.OperationAborted;
}

fn sigint_handler(_: c_int) callconv(.C) void {
    std.log.info("sigint_handler resetting scheme", .{});
    resetScheme() catch |err| {
        std.log.err("Failed to reset scheme: {}", .{err});
    };
    std.c.exit(0);
}

fn getGrandParentPid() u32 {
    const ppid = c.getppid();
    var info: c.proc_bsdinfo = undefined;
    _ = c.proc_pidinfo(ppid, c.PROC_PIDTBSDINFO, 0, &info, c.PROC_PIDTBSDINFO_SIZE);
    return info.pbi_ppid;
}

fn setupProcessHook() !void {
    var ppid: u32 = 0;
    var fpid: i32 = 0;

    var sig_ret = c.signal(std.c.SIG.INT, sigint_handler);
    std.log.info("Setting SIGINT handler returned '{?}'", .{sig_ret});
    sig_ret = c.signal(std.c.SIG.PIPE, sigint_handler);
    std.log.info("Setting SIGPIPE handler returned '{?}'", .{sig_ret});

    if (ppid == 0) {
        ppid = getGrandParentPid();
        std.log.info("Got grand parent PID '{?}'", .{ppid});
    }

    fpid = c.fork();
    if (fpid != 0) {
        std.log.info("Master process exiting", .{});
        std.c.exit(0);
    }
    std.log.info("Forked process continuing", .{});

    // Set up kqueue and wait for the parent process to exit
    const kq = c.kqueue();
    if (kq == -1) {
        std.log.err("Failed to acquire kqueue\n", .{});
        std.c.exit(1);
    }

    const timeout = c.timespec{ .tv_sec = 8 * 60 * 60, .tv_nsec = 0 };
    var kev = c.struct_kevent{ .ident = @intCast(ppid), .filter = c.EVFILT_PROC, .flags = c.EV_ADD, .fflags = c.NOTE_EXIT, .data = 0, .udata = null };

    var kret = c.kevent(kq, &kev, 1, null, 0, null);
    if (kret == -1) {
        std.log.err("Failed to set an event listener\n", .{});
        std.c.exit(1);
    }
    std.log.debug("kev before listen: {?}", .{kev});

    kret = c.kevent(kq, null, 0, &kev, 1, &timeout);
    if (kret == -1) {
        std.log.err("Failed to listen to NOTE_EXIT event\n", .{});
        std.c.exit(1);
    }

    std.log.debug("kev after listen: {?}", .{kev});
    if (kret > 0) {
        resetScheme() catch |err| {
            std.log.err("Failed to reset scheme: {}", .{err});
        };
    }
}

pub fn setScheme(host_name: []const u8) !void {
    const theme_name = getThemeName(host_name) catch |err| {
        std.log.info("No theme defined for '{s}' ({})", .{ host_name, err });
        return;
    };
    std.log.info("Found theme: {s}", .{theme_name});
    var res_dir = std.process.getEnvVarOwned(allocator, "GHOSTTY_RESOURCES_DIR") catch "";
    if (res_dir.len == 0) {
        res_dir = switch (builtin.os.tag) {
            .macos => "/Applications/Ghostty.app/Contents/Resources/ghostty",
            else => "/usr/share/ghostty",
        };
    }
    std.log.info("Reading Ghostty resources from '{s}'", .{res_dir});
    const theme_path = std.fmt.allocPrintZ(allocator, "{s}/themes/{s}", .{ res_dir, theme_name }) catch "";
    const theme_file = try std.fs.openFileAbsolute(theme_path, .{});
    defer theme_file.close();
    var buffered_reader = std.io.bufferedReader(theme_file.reader());
    const reader = buffered_reader.reader();
    const stdout = std.io.getStdOut().writer();
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', MAX_BYTES_PER_LINE)) |line| {
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
    try setupProcessHook();
}

fn pidToCommandLine(pid: u32) []const u8 {
    const pid_str = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch return "";
    const argv = [4][]const u8{ "/bin/ps", "-eo", "args=", pid_str };
    const rr = std.process.Child.run(.{ .allocator = allocator, .argv = &argv }) catch return "";
    const process_command_line = std.mem.trim(u8, rr.stdout, "\n");
    std.log.info("Parent command line '{s}'", .{process_command_line});
    return process_command_line;
}

fn shouldChangeTheme() !bool {
    const gppid = getGrandParentPid();
    const gparent_command_line = pidToCommandLine(gppid);
    std.log.info("Grand parent command line '{s}'", .{gparent_command_line});
    const ppid = c.getppid();
    const parent_command_line = pidToCommandLine(@intCast(ppid));
    std.log.info("Parent command line '{s}'", .{parent_command_line});

    var config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch "";
    if (config_home.len == 0) {
        config_home = try std.process.getEnvVarOwned(allocator, "HOME");
    }

    const config_file_name = try std.fmt.allocPrint(allocator, "{s}/scz.toml", .{config_home});
    std.log.info("Going to read '{s}'", .{config_file_name});
    const config_file = std.fs.openFileAbsolute(config_file_name, .{}) catch |err| {
        std.log.err("Failed to open config file '{s}': {}", .{ config_file_name, err });
        return false;
    };
    defer config_file.close();
    var buffered_reader = std.io.bufferedReader(config_file.reader());
    var buffer: [MAX_BYTES_PER_LINE]u8 = undefined;
    var config_size: usize = 0;
    while (true) {
        const count = try buffered_reader.read(&buffer);
        if (count == 0) {
            break;
        }
        config_size += count;
    }
    const slice = buffer[0..config_size];
    std.log.info("Read config: {d} bytes", .{config_size});
    var table = try tomlz.parse(allocator, slice);
    defer table.deinit(allocator);
    for (table.getArray("bypasses").?.items()) |value| {
        std.log.info("Checking bypass '{s}' in grand parent", .{value.string});
        if (std.mem.indexOf(u8, gparent_command_line, value.string)) |index| {
            if (index >= 0) {
                std.log.info("Bypass matched parent's command line at index {}", .{index});
                return false;
            }
        }
    }
    for (table.getArray("bypasses").?.items()) |value| {
        std.log.info("Checking bypass '{s}' in parent", .{value.string});
        if (std.mem.indexOf(u8, parent_command_line, value.string)) |index| {
            if (index >= 0) {
                std.log.info("Bypass matched parent's command line at index {}", .{index});
                return false;
            }
        }
    }
    return true;
}

pub fn main() !u8 {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    if (args.inner.count != 2) {
        const stderr = std.io.getStdErr().writer();
        _ = try stderr.print("scz {s}\n\nGimme a single SSH host name to work on!\n", .{VERSION});
        return 1;
    }

    // Log the current timestamp
    var buffer = try allocator.alloc(u8, 64);
    const t = std.time.timestamp();
    const tmp = c.localtime(&t);
    const count = c.strftime(buffer.ptr, 32, "%Y-%m-%d %H:%M:%S", tmp);
    std.log.info("=== {s}", .{buffer[0..count]});
    allocator.free(buffer);

    // Should we change the theme?
    const do_work_or_failed = shouldChangeTheme();
    if (do_work_or_failed) |do_work| {
        // Here we're left with a bool.
        if (do_work) {
            // Jump over program name to get to the hostname.
            _ = args.next();
            if (args.next()) |host_name| {
                std.log.info("host_name {s}", .{host_name});
                if (std.mem.eql(
                    u8,
                    host_name,
                    "RESET-SCHEME",
                )) {
                    resetScheme() catch |err| {
                        std.log.err("resetScheme failed: {}", .{err});
                        return 2;
                    };
                } else {
                    setScheme(host_name) catch |err| {
                        std.log.err("setScheme failed: {}", .{err});
                        return 2;
                    };
                }
            } else {
                std.log.err("Failed to get host_name from argv", .{});
            }
        }
    } else |err| {
        std.log.err("Parent examination failed: {}", .{err});
        return err;
    }
    return 0;
}
