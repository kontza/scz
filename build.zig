const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "scz",
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const ZT = "zig-toml";
    const zig_toml = b.dependency(ZT, .{});
    exe.root_module.addImport(ZT, zig_toml.module(ZT));
    b.installArtifact(exe);
}
