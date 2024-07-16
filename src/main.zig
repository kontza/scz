const std = @import("std");

pub fn reset_scheme() !void {
    const stdout = std.io.getStdOut().writer();
    var counter: u8 = 0;
    while (counter < 15) : (counter += 1) {
        const color_index = [_]u8{counter};
        try stdout.writeAll("\x1b]104;");
        try stdout.writeAll(&color_index);
        try stdout.writeAll("\x07");
    }
    try stdout.writeAll("\x1b]110\x07");
    try stdout.writeAll("\x1b]111\x07");
    try stdout.writeAll("\x1b]112\x07");
}

pub fn set_scheme(_: []const u8) void {
    // std.log.err("Not implemented for '{}', yet.", host_name);
}

pub fn main() !u8 {
    const alloc: std.mem.Allocator = std.heap.page_allocator;
    var args = try std.process.argsWithAllocator(alloc);
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
        try reset_scheme();
    } else {
        set_scheme(host_name orelse "");
    }
    return 0;
}
