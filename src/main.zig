const std = @import("std");
const builtin = @import("builtin");

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
    const strippables = comptime " \t";
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
    const theme_name = try getThemeName(host_name);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var res_dir = std.process.getEnvVarOwned(allocator, "GHOSTTY_RESOURCES_DIR") catch "";
    if (res_dir.len == 0) {
        res_dir = switch (builtin.os.tag) {
            .macos => "/Applications/Ghostty.app/Contents/Resources/ghostty",
            else => "/usr/share/ghostty",
        };
    }
    std.log.info("THEME {s}, RES {s}, tag {}", .{ theme_name, res_dir, builtin.os.tag });
    // if theme_name is not None:
    //     try:
    //         res_dir = os.environ["GHOSTTY_RESOURCES_DIR"]
    //     except KeyError:
    //         res_dir = None
    //     if res_dir is None:
    //         match sys.platform:
    //             case "darwin":
    //                 res_dir = "/Applications/Ghostty.app/Contents/Resources/ghostty"
    //             case "linux":
    //                 res_dir = "/usr/share/ghostty"
    //     with open(
    //         f"{res_dir}/themes/{theme_name}",
    //     ) as config_file:
    //         for line in config_file.readlines():
    //             line = line.strip()
    //             if line is None or line.startswith("#"):
    //                 continue
    //             for p in patterns:
    //                 mo = p["pat"].match(line)
    //                 if mo is not None:
    //                     format = p["fmt"].replace("\\", "").format("0")
    //                     if mo.group().startswith("palette"):
    //                         color = line[mo.span()[1] :].replace("=", ";").strip()
    //                     else:
    //                         color = f'#{line.split("=")[1].strip()}'
    //                     if show_debug:
    //                         print(
    //                             "'{0}': Would use '\\033]{1}\\007'".format(
    //                                 line, p["fmt"].format(color)
    //                             )
    //                         )
    //                     print("\033]{0}\007".format(p["fmt"].format(color)), end="")
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
