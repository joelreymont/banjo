const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const live_cli_tests = b.option(bool, "live_cli_tests", "Enable live CLI snapshot tests") orelse false;
    const test_filter = b.option([]const u8, "test_filter", "Run only tests matching this filter");
    const filters = if (test_filter) |filter| &[_][]const u8{filter} else &.{};

    // Version and git info
    const version = "0.6.1";
    const git_hash = b.run(&.{ "git", "rev-parse", "--short", "HEAD" });

    // Build options for version info
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_hash", std.mem.trim(u8, git_hash, "\n\r "));
    options.addOption(bool, "live_cli_tests", live_cli_tests);

    // Main module
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addOptions("config", options);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "banjo",
        .root_module = main_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run banjo ACP agent");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("config", options);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = filters,
    });

    // Add ohsnap for snapshot testing (only in test builds)
    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        unit_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Live CLI snapshot tests (Claude Code + Codex)
    const live_options = b.addOptions();
    live_options.addOption([]const u8, "version", version);
    live_options.addOption([]const u8, "git_hash", std.mem.trim(u8, git_hash, "\n\r "));
    live_options.addOption(bool, "live_cli_tests", true);

    const live_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_test_mod.addOptions("config", live_options);

    const live_tests = b.addTest(.{
        .root_module = live_test_mod,
        .filters = filters,
    });

    if (b.lazyDependency("ohsnap", .{
        .target = target,
        .optimize = optimize,
    })) |ohsnap_dep| {
        live_tests.root_module.addImport("ohsnap", ohsnap_dep.module("ohsnap"));
    }

    const run_live_tests = b.addRunArtifact(live_tests);
    const live_step = b.step("test-live", "Run live CLI snapshot tests");
    live_step.dependOn(&run_live_tests.step);

    // Debug under lldb
    const lldb = b.addSystemCommand(&.{ "lldb", "--" });
    lldb.addArtifactArg(unit_tests);
    const lldb_step = b.step("debug", "Run tests under lldb");
    lldb_step.dependOn(&lldb.step);
}
