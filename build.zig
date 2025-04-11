const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "bolt",
        .root_source_file = b.path("src/main.zig"),
        .target = b.host,
    });

    b.installArtifact(exe);

    // Add a test step
    const test_step = b.step("test", "Run all tests");

    // Create a test executable
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.host,
    });

    // Create a command to run the tests
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
