const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "bolt",
        .root_source_file = b.path("src/main.zig"),
        .target = b.host,
    });

    b.installArtifact(exe);
}
