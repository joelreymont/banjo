const std = @import("std");
const config = @import("config");

/// Debug log file path - exported for use by other modules
pub const path = "/tmp/banjo-nvim-debug.log";

/// Write a debug message to the log file with stderr fallback.
/// Opens the file, seeks to end, writes, and closes each call.
/// This is thread-safe as each call uses its own file handle.
pub fn write(comptime prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!config.nvim_debug) return;

    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[" ++ prefix ++ "] " ++ fmt ++ "\n", args) catch return;

    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch {
        std.io.getStdErr().writer().writeAll(msg) catch {};
        return;
    };
    defer f.close();

    f.seekFromEnd(0) catch {
        std.io.getStdErr().writer().writeAll(msg) catch {};
        return;
    };

    _ = f.write(msg) catch {
        std.io.getStdErr().writer().writeAll(msg) catch {};
    };
    f.sync() catch {};
}

/// Persistent debug logger for use in a single module.
/// More efficient for high-frequency logging but requires init/deinit.
pub const PersistentLog = struct {
    file: ?std.fs.File = null,

    /// Initialize by creating the log file.
    pub fn init(self: *PersistentLog) void {
        if (config.nvim_debug and self.file == null) {
            self.file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
        }
    }

    /// Close the log file.
    pub fn deinit(self: *PersistentLog) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }

    /// Write a message with the given prefix.
    pub fn write(self: *PersistentLog, comptime prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!config.nvim_debug) return;

        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[" ++ prefix ++ "] " ++ fmt ++ "\n", args) catch return;

        if (self.file) |f| {
            _ = f.write(msg) catch {
                std.io.getStdErr().writer().writeAll(msg) catch {};
            };
        } else {
            std.io.getStdErr().writer().writeAll(msg) catch {};
        }
    }
};

test "debug_log write compiles" {
    // Just verify the function compiles - don't actually write in tests
    if (false) {
        write("TEST", "hello {s}", .{"world"});
    }
}

test "PersistentLog compiles" {
    const logger: PersistentLog = .{};
    _ = logger;
}
