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
    global_file = fs.cwd().createFile(path, .{ .truncate = false }) catch null;
    if (global_file) |f| {
        f.seekFromEnd(0) catch {};
    }
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
    w.print("{d:0>2}:{d:0>2}:{d:0>2} ", .{
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return;

    // Level and scope
    w.print("[{s}] [{s}] ", .{ level.asText(), scope }) catch return;

    // Message
    w.print(fmt, args) catch return;
    w.writeByte('\n') catch return;

    const msg = fbs.getWritten();

    // Write to file
    if (global_file) |f| {
        _ = f.write(msg) catch {};
    }

    // Also write to stderr for error/warn
    if (@intFromEnum(level) <= @intFromEnum(Level.warn)) {
        std.fs.File.stderr().writeAll(msg) catch {};
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
