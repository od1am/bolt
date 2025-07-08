const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{},
    .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    for (test_targets) |target| {
        const unit_tests = b.addTest(.{
            .root_source_file = b.path("main.zig"),
            .target = b.resolveTargetQuery(target),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_unit_tests.step);

        const exe = b.addExecutable(.{
            .name = "bolt",
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(target),
            .optimize = optimize,
        });

        b.installArtifact(exe);
    }
}
