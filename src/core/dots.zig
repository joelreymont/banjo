const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.dots);
const max_dot_output_bytes: usize = 128 * 1024;

const DotTask = struct {
    status: []const u8,
};

pub fn hasPendingTasks(allocator: Allocator, cwd: []const u8) bool {
    var args = [_][]const u8{ "dot", "ls", "--json" };
    var child = std.process.Child.init(&args, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.warn("dot ls failed to start: {}", .{err});
        return false;
    };
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdout = child.stdout orelse return false;
    const stderr = child.stderr orelse return false;
    const out = stdout.readToEndAlloc(allocator, max_dot_output_bytes) catch |err| {
        log.warn("dot ls stdout read failed: {}", .{err});
        return false;
    };
    defer allocator.free(out);
    const err_out = stderr.readToEndAlloc(allocator, max_dot_output_bytes) catch |err| {
        log.warn("dot ls stderr read failed: {}", .{err});
        return false;
    };
    defer allocator.free(err_out);

    const term = child.wait() catch |err| {
        log.warn("dot ls wait failed: {}", .{err});
        return false;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.warn("dot ls exited with code {d}: {s}", .{ code, err_out });
            return false;
        },
        else => {
            log.warn("dot ls did not exit cleanly: {}", .{term});
            return false;
        },
    }

    return outputHasPendingTasks(allocator, out) catch |err| {
        log.warn("dot ls output parse failed: {}", .{err});
        return false;
    };
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
