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
        if (isPidAlive(existing.pid)) {
            return error.PortAlreadyInUse;
        }
        // Stale lock file, delete it
        std.fs.deleteFileAbsolute(path) catch |err| {
            log.warn("Failed to remove stale lock file {s}: {}", .{ path, err });
        };
    } else |_| {}

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
    // std.os.linux.getpid() returns pid_t which is i32 on most systems
    // On macOS/Darwin, use std.c.getpid()
    return @intCast(std.c.getpid());
}

fn isPidAlive(pid: i32) bool {
    // kill(pid, 0) returns 0 if process exists, -1 otherwise
    const result = std.c.kill(pid, 0);
    return result == 0;
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

    for (parsed.value.workspaceFolders, 0..) |folder, i| {
        folders[i] = try allocator.dupe(u8, folder);
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

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
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

test "generateUuidV4 format" {
    var uuid: [36]u8 = undefined;
    generateUuidV4(&uuid);

    // Check format: 8-4-4-4-12
    try testing.expectEqual(@as(u8, '-'), uuid[8]);
    try testing.expectEqual(@as(u8, '-'), uuid[13]);
    try testing.expectEqual(@as(u8, '-'), uuid[18]);
    try testing.expectEqual(@as(u8, '-'), uuid[23]);

    // Check version 4 indicator
    try testing.expect(uuid[14] == '4');

    // Check variant bits (8, 9, a, or b)
    const variant = uuid[19];
    try testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "generateUuidV4 uniqueness" {
    var uuid1: [36]u8 = undefined;
    var uuid2: [36]u8 = undefined;
    generateUuidV4(&uuid1);
    generateUuidV4(&uuid2);

    try testing.expect(!std.mem.eql(u8, &uuid1, &uuid2));
}

test "isPidAlive self" {
    const self_pid = getPid();
    try testing.expect(isPidAlive(self_pid));
}

test "isPidAlive invalid" {
    // PID 0 is the kernel scheduler, not a user process
    // PID 1 is init/systemd which should exist
    // Use a very high unlikely PID
    try testing.expect(!isPidAlive(99999999));
}
