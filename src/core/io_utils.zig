const std = @import("std");
const byte_queue = @import("../util/byte_queue.zig");
const Allocator = std.mem.Allocator;

pub fn waitForReadable(fd: std.posix.fd_t, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const count = try std.posix.poll(&fds, timeout_ms);
    if (count == 0) return false;
    if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
        return error.UnexpectedEof;
    }
    if ((fds[0].revents & std.posix.POLL.HUP) != 0 and (fds[0].revents & std.posix.POLL.IN) == 0) {
        return error.UnexpectedEof;
    }
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

pub fn pollSliceMs(deadline_ms: i64, now_ms: i64) i32 {
    const remaining_ms = deadline_ms - now_ms;
    const clamped = @max(@as(i64, 0), @min(@as(i64, 200), remaining_ms));
    return @as(i32, @intCast(clamped));
}

pub fn readLine(
    allocator: Allocator,
    queue: *byte_queue.ByteQueue,
    reader: anytype,
    fd: ?std.posix.fd_t,
    deadline_ms: ?i64,
    max_line_bytes: usize,
) !?[]const u8 {
    const effective_deadline = if (fd == null) null else deadline_ms;
    var buf: [4096]u8 = undefined;

    while (true) {
        const pending = queue.slice();
        if (std.mem.indexOfScalar(u8, pending, '\n')) |nl| {
            if (nl == 0) {
                queue.consume(1);
                continue;
            }
            if (nl > max_line_bytes) return error.LineTooLong;
            const line = pending[0..nl];
            queue.consume(nl + 1);
            return line;
        }

        if (effective_deadline) |deadline| {
            const now = std.time.milliTimestamp();
            if (now >= deadline) return error.Timeout;
            const slice_ms = pollSliceMs(deadline, now);
            const ready = try waitForReadable(fd.?, slice_ms);
            if (!ready) continue;
        } else if (fd != null) {
            _ = try waitForReadable(fd.?, -1);
        }

        const count = reader.read(&buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.EndOfStream => {
                if (queue.len() == 0) return null;
                const remaining = queue.slice();
                queue.clear();
                return remaining;
            },
            else => return err,
        };
        if (count == 0) {
            if (queue.len() == 0) return null;
            const remaining = queue.slice();
            queue.clear();
            return remaining;
        }
        try queue.append(allocator, buf[0..count]);
        if (queue.len() > max_line_bytes) return error.LineTooLong;
    }
}

pub fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try std.posix.write(fd, buf[offset..]);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
}
