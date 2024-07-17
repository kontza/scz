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
    var proc = std.process.Child.init(&[_][]const u8{ "ssh", "-G", host_name }, allocator);

    // Set the desired behavior for the standard streams
    proc.stdin_behavior = .Ignore;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Inherit;

    // Start the execution of the child process
    try proc.spawn();

    // Wait for the child process to finish execution
    const term = try proc.wait();

    // Print the captured output from the child process
    std.debug.print("Child process output:\n{}\n", .{proc.stdout.?});

    // Check the exit status of the child process
    if (term == .Exited) {
        std.debug.print("Child process exited with status {}\n", .{term});
    } else if (term == .Signal) {
        std.debug.print("Child process terminated by signal {}\n", .{term.Signal});
    } else {
        std.debug.print("Child process stopped or unknown termination\n", .{});
    }
    return "";
}

pub fn setScheme(host_name: []const u8) !void {
    _ = getThemeName(host_name) catch {};
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
        resetScheme() catch {
            return 0;
        };
    } else {
        setScheme(host_name orelse "") catch {
            return 0;
        };
    }
    return 0;
}
