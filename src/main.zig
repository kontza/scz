const std = @import("std");

pub fn resetScheme() !void {
    const stdout = std.io.getStdOut().writer();
    var counter: u8 = 0;
    while (counter < 15) : (counter += 1) {
        const color_index = [_]u8{counter};
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
        const part = std.mem.trim(u8, parts.next() orelse "", " \t");
        if (std.mem.eql(u8, part, "setenv TERMINAL_THEME")) {
            const theme_name = std.mem.trim(u8, parts.next() orelse "", " \t");
            return try allocator.dupeZ(u8, theme_name);
        }
    }
    return "";
}

pub fn setScheme(host_name: []const u8) !void {
    const result = try getThemeName(host_name);
    std.log.info("Theme name: {s}", .{result});
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    if (args.inner.count != 2) {
        std.log.err("Gimme a single SSH host name to work on!", .{});
        return 1;
    }
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
    return 0;
}
