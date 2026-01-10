const std = @import("std");
const banjo_log = @import("log.zig");

/// Legacy debug log path - kept for backwards compatibility
pub const path = banjo_log.default_path;

/// Write a debug message. Delegates to the new logging system.
pub fn write(comptime prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
    const logger = banjo_log.scoped(prefix);
    logger.debug(fmt, args);
}

/// Persistent debug logger - now just wraps the global logger.
pub const PersistentLog = struct {
    pub fn init(_: *PersistentLog) void {
        banjo_log.init();
    }

    pub fn deinit(_: *PersistentLog) void {
        // No-op: global logger handles cleanup
    }

    pub fn write(_: *PersistentLog, comptime prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
        const logger = banjo_log.scoped(prefix);
        logger.debug(fmt, args);
    }
};

test "debug_log write compiles" {
    if (false) {
        write("TEST", "hello {s}", .{"world"});
    }
}

test "PersistentLog compiles" {
    const logger: PersistentLog = .{};
    _ = logger;
}
