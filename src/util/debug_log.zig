const std = @import("std");
const config = @import("config");

/// Shared debug logger for nvim components.
/// Writes to /tmp/banjo-nvim-debug.log when nvim_debug is enabled.
pub const DebugLog = struct {
    file: ?std.fs.File = null,
    buf: [4096]u8 = undefined,

    const path = "/tmp/banjo-nvim-debug.log";

    /// Initialize the debug log file. Call once at startup.
    pub fn init(self: *DebugLog) void {
        if (config.nvim_debug and self.file == null) {
            self.file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
        }
    }

    /// Close the debug log file.
    pub fn deinit(self: *DebugLog) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }

    /// Write a debug message with the given prefix.
    pub fn log(self: *DebugLog, comptime prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!config.nvim_debug) return;
        if (self.file) |f| {
            const msg = std.fmt.bufPrint(&self.buf, "[" ++ prefix ++ "] " ++ fmt ++ "\n", args) catch return;
            _ = f.write(msg) catch {};
        }
    }
};

/// Global debug logger instance.
/// Initialize with debug_logger.init() at startup.
pub var debug_logger: DebugLog = .{};

/// Convenience function for logging with a prefix.
pub fn log(comptime prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
    debug_logger.log(prefix, fmt, args);
}

test "DebugLog basic usage" {
    var logger: DebugLog = .{};
    // Don't actually init in tests (would create file)
    // Just verify struct compiles
    _ = logger;
}
