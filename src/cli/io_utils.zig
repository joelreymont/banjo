const std = @import("std");

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
