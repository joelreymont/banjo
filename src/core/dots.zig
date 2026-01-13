const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const Engine = types.Engine;
const log = std.log.scoped(.dots);
const max_dot_output_bytes: usize = 128 * 1024;

// Skill template embedded at compile time
pub const skill_prompt = @embedFile("dot-skill");

const DotTask = struct {
    status: []const u8,
};

/// Returns the trigger command for the dot skill
pub fn trigger(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "/dot",
        .codex => "$dot",
    };
}

/// Returns the clear context command
pub fn clearCmd(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "/clear",
        .codex => "/new",
    };
}

/// Returns the skill path for the given engine
pub fn skillPath(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => ".claude/skills/dot/SKILL.md",
        .codex => ".codex/skills/dot/SKILL.md",
    };
}

/// Check if dot CLI is available
pub fn hasDotCli() bool {
    var args = [_][]const u8{ "dot", "--version" };
    var child = std.process.Child.init(&args, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Check if dot skill exists for the given engine
pub fn hasSkill(engine: Engine) bool {
    const home = std.posix.getenv("HOME") orelse return false;
    const path = skillPath(engine);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, path }) catch return false;

    std.fs.cwd().access(full_path, .{}) catch return false;
    return true;
}

/// Check if .dots directory exists in given cwd
pub fn hasDotDir(cwd: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.dots", .{cwd}) catch return false;

    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Result of checking for pending tasks
pub const PendingTasksResult = struct {
    has_tasks: bool,
    error_msg: ?[]const u8 = null, // Static string describing error, null if success
};

pub fn hasPendingTasks(allocator: Allocator, cwd: []const u8) PendingTasksResult {
    var args = [_][]const u8{ "dot", "ls", "--json" };
    var child = std.process.Child.init(&args, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.warn("dot ls failed to start: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "dot CLI not found or failed to start" };
    };
    errdefer {
        _ = child.kill() catch |err| blk: {
            log.warn("Failed to kill dot ls process: {}", .{err});
            break :blk std.process.Child.Term{ .Unknown = 0 };
        };
        _ = child.wait() catch |err| blk: {
            log.warn("Failed to wait for dot ls process: {}", .{err});
            break :blk std.process.Child.Term{ .Unknown = 0 };
        };
    }

    const stdout = child.stdout orelse return .{ .has_tasks = false, .error_msg = "no stdout from dot" };
    const stderr = child.stderr orelse return .{ .has_tasks = false, .error_msg = "no stderr from dot" };
    const out = stdout.readToEndAlloc(allocator, max_dot_output_bytes) catch |err| {
        log.warn("dot ls stdout read failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "failed to read dot output" };
    };
    defer allocator.free(out);
    const err_out = stderr.readToEndAlloc(allocator, max_dot_output_bytes) catch |err| {
        log.warn("dot ls stderr read failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "failed to read dot stderr" };
    };
    defer allocator.free(err_out);

    const term = child.wait() catch |err| {
        log.warn("dot ls wait failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "dot process wait failed" };
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.warn("dot ls exited with code {d}: {s}", .{ code, err_out });
            return .{ .has_tasks = false, .error_msg = "dot ls exited with error" };
        },
        else => {
            log.warn("dot ls did not exit cleanly: {}", .{term});
            return .{ .has_tasks = false, .error_msg = "dot ls terminated abnormally" };
        },
    }

    const has = outputHasPendingTasks(allocator, out) catch |err| {
        log.warn("dot ls output parse failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "failed to parse dot output" };
    };
    return .{ .has_tasks = has };
}

pub fn outputHasPendingTasks(allocator: Allocator, output: []const u8) !bool {
    const parsed = try std.json.parseFromSlice([]DotTask, allocator, output, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value.len > 0;
}

const testing = std.testing;
const ohsnap = @import("ohsnap");

test "outputHasPendingTasks detects pending tasks" {
    const has_tasks = try outputHasPendingTasks(testing.allocator, "[{\"status\":\"open\"}]");
    const no_tasks = try outputHasPendingTasks(testing.allocator, "[]");
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("has_tasks: {any}\nno_tasks: {any}\n", .{ has_tasks, no_tasks });
    const summary = try out.toOwnedSlice();
    defer testing.allocator.free(summary);
    try (ohsnap{}).snap(@src(),
        \\has_tasks: true
        \\no_tasks: false
        \\
    ).diff(summary, true);
}

test "trigger returns correct command per engine" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {s}\ncodex: {s}\n", .{ trigger(.claude), trigger(.codex) });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude: /dot
        \\codex: $dot
        \\
    ).diff(snapshot, true);
}

test "clearCmd returns correct command per engine" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {s}\ncodex: {s}\n", .{ clearCmd(.claude), clearCmd(.codex) });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude: /clear
        \\codex: /new
        \\
    ).diff(snapshot, true);
}

test "skillPath returns correct path per engine" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {s}\ncodex: {s}\n", .{ skillPath(.claude), skillPath(.codex) });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude: .claude/skills/dot/SKILL.md
        \\codex: .codex/skills/dot/SKILL.md
        \\
    ).diff(snapshot, true);
}

test "skill_prompt is non-empty" {
    try testing.expect(skill_prompt.len > 100);
    try testing.expect(std.mem.indexOf(u8, skill_prompt, "dot") != null);
}

test "hasDotDir with temp directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // No .dots dir yet
    try testing.expect(!hasDotDir(tmp_path));

    // Create .dots dir
    try tmp.dir.makeDir(".dots");

    // Now should exist
    try testing.expect(hasDotDir(tmp_path));
}

const zcheck = @import("zcheck");

test "property: trigger is consistent" {
    try zcheck.check(struct {
        fn prop(args: struct { engine_idx: u8 }) bool {
            const engine: Engine = if (args.engine_idx % 2 == 0) .claude else .codex;
            const t1 = trigger(engine);
            const t2 = trigger(engine);
            return std.mem.eql(u8, t1, t2);
        }
    }.prop, .{ .seed = 0x1234 });
}

test "property: clearCmd is consistent" {
    try zcheck.check(struct {
        fn prop(args: struct { engine_idx: u8 }) bool {
            const engine: Engine = if (args.engine_idx % 2 == 0) .claude else .codex;
            const c1 = clearCmd(engine);
            const c2 = clearCmd(engine);
            return std.mem.eql(u8, c1, c2);
        }
    }.prop, .{ .seed = 0x5678 });
}
