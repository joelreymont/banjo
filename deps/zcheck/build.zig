const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get git hash at build time
    const git_hash = b.run(&.{ "git", "rev-parse", "--short", "HEAD" });

    // Version can be overridden: zig build -Dversion=1.2.3
    const version = b.option([]const u8, "version", "Semantic version (default: 0.1.0)") orelse "0.1.0";

    // Build options for version info
    const options = b.addOptions();
    options.addOption([]const u8, "git_hash", std.mem.trim(u8, git_hash, "\n\r "));
    options.addOption([]const u8, "version", version);

    // Library module
    const zcheck_mod = b.createModule(.{
        .root_source_file = b.path("src/zcheck.zig"),
        .target = target,
        .optimize = optimize,
    });
    zcheck_mod.addOptions("build_options", options);

    // Export the module for dependents
    _ = b.addModule("zcheck", .{
        .root_source_file = b.path("src/zcheck.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zcheck.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Example executable
    const example_mod = b.createModule(.{
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zcheck", .module = zcheck_mod },
        },
    });

    const example = b.addExecutable(.{
        .name = "example",
        .root_module = example_mod,
    });

    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run the example");
    example_step.dependOn(&run_example.step);
}
