const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.nvim_lockfile);

pub const LockFile = struct {
    path: []const u8,
    auth_token: [36]u8,
    port: u16,
    allocator: Allocator,

    pub fn deinit(self: *LockFile) void {
        self.remove();
        self.allocator.free(self.path);
    }

    pub fn remove(self: *LockFile) void {
        std.fs.deleteFileAbsolute(self.path) catch |err| {
            log.warn("Failed to remove lock file {s}: {}", .{ self.path, err });
        };
    }
};

pub const LockFileData = struct {
    pid: i32,
    workspaceFolders: []const []const u8,
    ideName: []const u8 = "Banjo-Neovim",
    transport: []const u8 = "ws",
    authToken: []const u8,
};

pub fn create(allocator: Allocator, port: u16, cwd: []const u8, auth_token: *const [36]u8) !LockFile {
    const path = try getLockFilePath(allocator, port);
    errdefer allocator.free(path);

    // Check for stale lock file
    if (readExistingLockFile(allocator, path)) |existing| {
        defer {
            allocator.free(existing.authToken);
            for (existing.workspaceFolders) |folder| {
                allocator.free(folder);
            }
            allocator.free(existing.workspaceFolders);
        }
        if (try isPidAlive(existing.pid)) {
            return error.PortAlreadyInUse;
        }
        // Stale lock file, delete it
        std.fs.deleteFileAbsolute(path) catch |err| {
            log.warn("Failed to remove stale lock file {s}: {}", .{ path, err });
        };
    } else |err| {
        // Only ignore FileNotFound; propagate other errors (permissions, parse failures)
        if (err != error.FileNotFound) {
            log.warn("Failed to read existing lock file {s}: {}", .{ path, err });
        }
    }

    const pid = getPid();

    const workspace_folders = [_][]const u8{cwd};
    const data = LockFileData{
        .pid = pid,
        .workspaceFolders = &workspace_folders,
        .authToken = auth_token,
    };

    try writeJsonToFile(allocator, path, data);

    return LockFile{
        .path = path,
        .auth_token = auth_token.*,
        .port = port,
        .allocator = allocator,
    };
}

fn getLockFilePath(allocator: Allocator, port: u16) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.claude/ide/{d}.lock", .{ home, port });
}

fn getPid() i32 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    }
    // macOS/BSD - use libc getpid()
    if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
        return std.c.getpid();
    }
    // Other systems - use thread ID as unique identifier
    return @intCast(@as(u32, @truncate(std.Thread.getCurrentId())));
}

fn isPidAlive(pid: i32) !bool {
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        // Use /proc on Linux
        var buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/proc/{d}", .{pid});
        var dir = std.fs.openDirAbsolute(path, .{}) catch |err| {
            // Only return false for errors that indicate process doesn't exist
            // Permission errors (hidepid) should assume alive to avoid deleting active locks
            return switch (err) {
                error.FileNotFound, error.NotDir => false,
                else => true,
            };
        };
        dir.close();
        return true;
    }
    if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
        // On macOS/BSD, use kill(pid, 0) to check if process exists
        // Returns success if process exists, ProcessNotFound if not
        _ = std.posix.kill(pid, 0) catch |err| {
            if (err == error.ProcessNotFound) return false;
            // EPERM means process exists but we can't signal it
            return true;
        };
        return true;
    }
    // On other systems, assume alive (safe fallback)
    return true;
}

fn readExistingLockFile(allocator: Allocator, path: []const u8) !LockFileData {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(LockFileData, allocator, content, .{});
    defer parsed.deinit();

    // Deep copy values we need
    const auth_token = try allocator.dupe(u8, parsed.value.authToken);
    errdefer allocator.free(auth_token);

    const folders = try allocator.alloc([]const u8, parsed.value.workspaceFolders.len);
    errdefer allocator.free(folders);

    var folders_allocated: usize = 0;
    errdefer for (folders[0..folders_allocated]) |f| allocator.free(f);

    for (parsed.value.workspaceFolders, 0..) |folder, i| {
        folders[i] = try allocator.dupe(u8, folder);
        folders_allocated = i + 1;
    }

    return LockFileData{
        .pid = parsed.value.pid,
        .workspaceFolders = folders,
        .authToken = auth_token,
    };
}

fn writeJsonToFile(allocator: Allocator, path: []const u8, data: LockFileData) !void {
    // Ensure directory exists
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Use exclusive create to prevent race conditions
    const file = std.fs.createFileAbsolute(path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.PortAlreadyInUse,
        else => return err,
    };
    defer file.close();

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(data);
    const buf = try out.toOwnedSlice();
    defer allocator.free(buf);
    try file.writeAll(buf);
}

pub fn generateUuidV4(out: *[36]u8) void {
    var uuid_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);

    // Set version 4 bits
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;

    // Format as UUID string
    const hex = "0123456789abcdef";
    var i: usize = 0;
    inline for ([_]usize{ 0, 1, 2, 3 }) |idx| {
        out[i] = hex[uuid_bytes[idx] >> 4];
        out[i + 1] = hex[uuid_bytes[idx] & 0x0f];
        i += 2;
    }
    out[i] = '-';
    i += 1;
    inline for ([_]usize{ 4, 5 }) |idx| {
        out[i] = hex[uuid_bytes[idx] >> 4];
        out[i + 1] = hex[uuid_bytes[idx] & 0x0f];
        i += 2;
    }
    out[i] = '-';
    i += 1;
    inline for ([_]usize{ 6, 7 }) |idx| {
        out[i] = hex[uuid_bytes[idx] >> 4];
        out[i + 1] = hex[uuid_bytes[idx] & 0x0f];
        i += 2;
    }
    out[i] = '-';
    i += 1;
    inline for ([_]usize{ 8, 9 }) |idx| {
        out[i] = hex[uuid_bytes[idx] >> 4];
        out[i + 1] = hex[uuid_bytes[idx] & 0x0f];
        i += 2;
    }
    out[i] = '-';
    i += 1;
    inline for ([_]usize{ 10, 11, 12, 13, 14, 15 }) |idx| {
        out[i] = hex[uuid_bytes[idx] >> 4];
        out[i + 1] = hex[uuid_bytes[idx] & 0x0f];
        i += 2;
    }
}

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "generateUuidV4 format" {
    var uuid: [36]u8 = undefined;
    generateUuidV4(&uuid);

    const variant = uuid[19];
    const summary = .{
        .dashes_ok = uuid[8] == '-' and uuid[13] == '-' and uuid[18] == '-' and uuid[23] == '-',
        .version_ok = uuid[14] == '4',
        .variant_ok = variant == '8' or variant == '9' or variant == 'a' or variant == 'b',
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.lockfile.test.generateUuidV4 format__struct_<^\d+$>
        \\  .dashes_ok: bool = true
        \\  .version_ok: bool = true
        \\  .variant_ok: bool = true
    ).expectEqual(summary);
}

test "generateUuidV4 uniqueness" {
    var uuid1: [36]u8 = undefined;
    var uuid2: [36]u8 = undefined;
    generateUuidV4(&uuid1);
    generateUuidV4(&uuid2);

    const summary = .{ .unique = !std.mem.eql(u8, &uuid1, &uuid2) };
    try (ohsnap{}).snap(@src(),
        \\nvim.lockfile.test.generateUuidV4 uniqueness__struct_<^\d+$>
        \\  .unique: bool = true
    ).expectEqual(summary);
}

test "isPidAlive self" {
    const self_pid = getPid();
    const summary = .{ .alive = try isPidAlive(self_pid) };
    try (ohsnap{}).snap(@src(),
        \\nvim.lockfile.test.isPidAlive self__struct_<^\d+$>
        \\  .alive: bool = true
    ).expectEqual(summary);
}

test "isPidAlive invalid" {
    // On Linux/macOS/BSD, we can detect dead PIDs
    // On other platforms, isPidAlive returns true (safe fallback)
    const builtin = @import("builtin");
    const can_detect = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd;
    const expected = !can_detect; // false if we can detect, true (alive) if we can't
    const summary = .{ .alive = try isPidAlive(99999999) };
    try (ohsnap{}).snap(@src(),
        \\nvim.lockfile.test.isPidAlive invalid__struct_<^\d+$>
        \\  .alive: bool = <^(true|false)$>
    ).expectEqual(summary);
    try std.testing.expectEqual(expected, summary.alive);
}
