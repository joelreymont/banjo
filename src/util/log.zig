const std = @import("std");
const fs = std.fs;
const posix = std.posix;

pub const Level = enum(u3) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,

    pub fn asText(self: Level) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warn => "WARN",
            .info => "INFO",
            .debug => "DEBUG",
            .trace => "TRACE",
        };
    }
};

pub const default_path = "/tmp/banjo.log";

var global_level: Level = .debug;
var global_file: ?fs.File = null;
var initialized: bool = false;

/// Initialize the logger. Call once at startup.
/// Reads BANJO_LOG_LEVEL env var: error, warn, info, debug (default), trace
/// Reads BANJO_LOG_FILE env var for custom path (default: /tmp/banjo.log)
pub fn init() void {
    if (initialized) return;
    initialized = true;

    // Parse log level from environment
    if (posix.getenv("BANJO_LOG_LEVEL")) |level_str| {
        global_level = parseLevel(level_str) orelse .debug;
    }

    // Open log file
    const path = posix.getenv("BANJO_LOG_FILE") orelse default_path;
    const file = fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
        std.debug.print("banjo log init failed for {s}: {}\n", .{ path, err });
        return;
    };
    if (file.seekFromEnd(0)) |_| {} else |err| {
        std.debug.print("banjo log seek failed for {s}: {}\n", .{ path, err });
        file.close();
        return;
    }
    global_file = file;
}

/// Deinitialize the logger. Call at shutdown.
pub fn deinit() void {
    if (global_file) |f| {
        f.close();
        global_file = null;
    }
    initialized = false;
}

fn parseLevel(s: []const u8) ?Level {
    const map = std.StaticStringMap(Level).initComptime(.{
        .{ "error", .err },
        .{ "err", .err },
        .{ "warn", .warn },
        .{ "warning", .warn },
        .{ "info", .info },
        .{ "debug", .debug },
        .{ "trace", .trace },
    });
    return map.get(s);
}

/// Create a scoped logger for a specific component.
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn err(comptime fmt: []const u8, args: anytype) void {
            log(.err, scope, fmt, args);
        }
        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            log(.warn, scope, fmt, args);
        }
        pub fn info(comptime fmt: []const u8, args: anytype) void {
            log(.info, scope, fmt, args);
        }
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log(.debug, scope, fmt, args);
        }
        pub fn trace(comptime fmt: []const u8, args: anytype) void {
            log(.trace, scope, fmt, args);
        }
    };
}

var cached_pid: ?posix.pid_t = null;

fn getPid() posix.pid_t {
    if (cached_pid) |pid| return pid;
    cached_pid = std.c.getpid();
    return cached_pid.?;
}

fn log(level: Level, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(global_level)) return;

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    // Timestamp
    const ts = std.time.timestamp();
    const epoch_secs: u64 = @intCast(ts);
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = epoch_day.getDaySeconds();
    if (w.print("{d:0>2}:{d:0>2}:{d:0>2} ", .{
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    })) |_| {} else |err| {
        std.debug.panic("banjo log timestamp format failed: {}", .{err});
    }

    // Level, scope, and PID
    if (w.print("[{s}] [{s}] [pid={d}] ", .{ level.asText(), scope, getPid() })) |_| {} else |err| {
        std.debug.panic("banjo log header format failed: {}", .{err});
    }

    // Message
    if (w.print(fmt, args)) |_| {} else |err| {
        std.debug.panic("banjo log message format failed: {}", .{err});
    }
    if (w.writeByte('\n')) |_| {} else |err| {
        std.debug.panic("banjo log newline write failed: {}", .{err});
    }

    const msg = fbs.getWritten();

    // Write to file
    if (global_file) |f| {
        if (f.writeAll(msg)) |_| {} else |err| {
            global_file = null;
            std.debug.print("banjo log file write failed: {}\n", .{err});
        }
    }

    // Also write to stderr for error/warn, or when no log file is available
    if (global_file == null or @intFromEnum(level) <= @intFromEnum(Level.warn)) {
        if (std.fs.File.stderr().writeAll(msg)) |_| {} else |err| {
            std.debug.panic("banjo log stderr write failed: {}", .{err});
        }
    }
}

/// Set log level at runtime.
pub fn setLevel(level: Level) void {
    global_level = level;
}

/// Get current log level.
pub fn getLevel() Level {
    return global_level;
}

test "scoped logger compiles" {
    const logger = scoped("test");
    _ = logger;
}

test "level parsing" {
    try std.testing.expectEqual(Level.debug, parseLevel("debug").?);
    try std.testing.expectEqual(Level.err, parseLevel("error").?);
    try std.testing.expectEqual(Level.trace, parseLevel("trace").?);
    try std.testing.expect(parseLevel("invalid") == null);
}
