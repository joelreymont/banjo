const std = @import("std");
const builtin = @import("builtin");

pub fn choose(env_var: []const u8, program: []const u8, fallback_paths: []const []const u8) []const u8 {
    if (std.posix.getenv(env_var)) |path| return path;
    for (fallback_paths) |path| {
        if (pathExists(path)) return path;
    }
    return program;
}

pub fn isAvailable(env_var: []const u8, program: []const u8, fallback_paths: []const []const u8) bool {
    if (std.posix.getenv(env_var)) |path| {
        return isExecutablePath(path);
    }
    for (fallback_paths) |path| {
        if (pathExists(path)) return true;
    }
    return isOnPath(program);
}

fn isExecutablePath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return pathExists(path);
    if (pathExists(path)) return true;
    return isOnPath(path);
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn isOnPath(program: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    const path_delim: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.splitScalar(u8, path_env, path_delim);
    while (it.next()) |dir| {
        const dir_path = if (dir.len == 0) "." else dir;
        const full = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir_path, sep, program }) catch continue;
        if (pathExists(full)) return true;
    }
    return false;
}
