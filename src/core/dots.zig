const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.dots);
const max_dot_output_bytes: usize = 128 * 1024;

const DotTask = struct {
    status: []const u8,
};

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

test "outputHasPendingTasks detects pending tasks" {
    const has_tasks = try outputHasPendingTasks(testing.allocator, "[{\"status\":\"open\"}]");
    try testing.expect(has_tasks);

    const no_tasks = try outputHasPendingTasks(testing.allocator, "[]");
    try testing.expect(!no_tasks);
}
