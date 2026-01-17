const std = @import("std");
const Allocator = std.mem.Allocator;
const byte_queue = @import("../util/byte_queue.zig");
const constants = @import("constants.zig");
const io_utils = @import("io_utils.zig");

const log = std.log.scoped(.permission_socket);

pub const HookRequest = struct {
    tool_name: []const u8,
    tool_input: std.json.Value,
    tool_use_id: []const u8,
    session_id: []const u8,
};

pub const HookResponse = struct {
    decision: []const u8 = "ask",
    reason: ?[]const u8 = null,
    answers: ?std.json.ArrayHashMap([]const u8) = null,
};

/// Result of creating a permission socket.
pub const CreateResult = struct {
    socket: std.posix.socket_t,
    path: []const u8,
};

/// Create a Unix domain socket for permission hook communication.
/// Returns socket fd and path. Caller owns the path memory.
/// Socket is created at /tmp/banjo-{session_id}.sock
pub fn create(allocator: Allocator, session_id: []const u8) !CreateResult {
    const path = try std.fmt.allocPrint(allocator, "/tmp/banjo-{s}.sock", .{session_id});
    errdefer allocator.free(path);

    // Remove existing socket file if present
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("Failed to remove existing permission socket {s}: {}", .{ path, err }),
    };

    // Create non-blocking Unix domain socket with CLOEXEC to prevent fd inheritance
    const sock = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        0,
    );
    errdefer std.posix.close(sock);

    // Bind to path
    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    const path_len = @min(path.len, addr.path.len - 1);
    @memcpy(addr.path[0..path_len], path[0..path_len]);

    try std.posix.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    try std.posix.listen(sock, 1);

    log.info("Created permission socket at {s}", .{path});

    return .{ .socket = sock, .path = path };
}

/// Close a permission socket and clean up the socket file.
pub fn close(allocator: Allocator, socket: std.posix.socket_t, path: []const u8) void {
    std.posix.close(socket);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("Failed to remove permission socket {s}: {}", .{ path, err }),
    };
    allocator.free(path);
}

/// Try to accept a connection (non-blocking).
/// Returns null if no connection pending, or the client fd.
pub fn tryAccept(socket: std.posix.socket_t) ?std.posix.socket_t {
    return std.posix.accept(socket, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC) catch |err| {
        if (err == error.WouldBlock) return null;
        log.warn("Permission socket accept error: {}", .{err});
        return null;
    };
}

pub fn readRequest(allocator: Allocator, fd: std.posix.fd_t, deadline_ms: i64) !?std.json.Parsed(HookRequest) {
    return readParsed(HookRequest, allocator, fd, deadline_ms);
}

pub fn readResponse(allocator: Allocator, fd: std.posix.fd_t, deadline_ms: i64) !?std.json.Parsed(HookResponse) {
    return readParsed(HookResponse, allocator, fd, deadline_ms);
}

pub fn writeRequest(allocator: Allocator, fd: std.posix.fd_t, request: HookRequest) !void {
    try writeJson(allocator, fd, request);
}

pub fn writeResponse(allocator: Allocator, fd: std.posix.fd_t, response: HookResponse) !void {
    try writeJson(allocator, fd, response);
}

fn readParsed(comptime T: type, allocator: Allocator, fd: std.posix.fd_t, deadline_ms: i64) !?std.json.Parsed(T) {
    var queue: byte_queue.ByteQueue = .{};
    defer queue.deinit(allocator);
    const file = std.fs.File{ .handle = fd };
    const line = (try io_utils.readLine(
        allocator,
        &queue,
        file.deprecatedReader().any(),
        fd,
        deadline_ms,
        constants.large_buffer_size,
    )) orelse return null;
    const parsed = try std.json.parseFromSlice(T, allocator, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return parsed;
}

fn writeJson(allocator: Allocator, fd: std.posix.fd_t, value: anytype) !void {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(value);
    try out.writer.writeByte('\n');
    const json = try out.toOwnedSlice();
    defer allocator.free(json);
    try io_utils.writeAll(fd, json);
}

// RAII wrapper for convenience
pub const PermissionSocket = struct {
    socket: std.posix.socket_t,
    path: []const u8,
    allocator: Allocator,

    /// Create a Unix domain socket for permission hook communication.
    /// Socket is created at /tmp/banjo-{session_id}.sock
    pub fn create(allocator: Allocator, session_id: []const u8) !PermissionSocket {
        const path = try std.fmt.allocPrint(allocator, "/tmp/banjo-{s}.sock", .{session_id});
        errdefer allocator.free(path);

        // Remove existing socket file if present
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("Failed to remove existing permission socket {s}: {}", .{ path, err }),
        };

        // Create non-blocking Unix domain socket with CLOEXEC to prevent fd inheritance
        const sock = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(sock);

        // Bind to path
        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);

        try std.posix.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(sock, 1);

        log.info("Created permission socket at {s}", .{path});

        return .{
            .socket = sock,
            .path = path,
            .allocator = allocator,
        };
    }

    /// Close the socket and clean up the socket file.
    pub fn close(self: *PermissionSocket) void {
        std.posix.close(self.socket);
        std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("Failed to remove permission socket {s}: {}", .{ self.path, err }),
        };
        self.allocator.free(self.path);
    }

    /// Get the socket file descriptor for polling.
    pub fn fd(self: PermissionSocket) std.posix.socket_t {
        return self.socket;
    }

    /// Get the socket path (for passing to subprocess via env var).
    pub fn getPath(self: PermissionSocket) []const u8 {
        return self.path;
    }

    /// Try to accept a connection (non-blocking).
    /// Returns null if no connection pending, or the client fd.
    pub fn tryAccept(self: PermissionSocket) ?std.posix.socket_t {
        return std.posix.accept(self.socket, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC) catch |err| {
            if (err == error.WouldBlock) return null;
            log.warn("Permission socket accept error: {}", .{err});
            return null;
        };
    }
};

test "PermissionSocket create and close" {
    const allocator = std.testing.allocator;
    const ohsnap = @import("ohsnap");

    var sock = try PermissionSocket.create(allocator, "test-session-123");

    const fd_nonzero = sock.fd() != 0;
    const path_contains = std.mem.indexOf(u8, sock.getPath(), "test-session-123") != null;
    const stat_present = blk: {
        _ = std.fs.cwd().statFile(sock.getPath()) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    // Close and verify cleanup
    const path_copy = try allocator.dupe(u8, sock.getPath());
    defer allocator.free(path_copy);

    sock.close();

    const stat_after = blk: {
        _ = std.fs.cwd().statFile(path_copy) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "fd_nonzero: {any}\npath_contains: {any}\nstat_present: {any}\nstat_after: {any}\n",
        .{ fd_nonzero, path_contains, stat_present, stat_after },
    );
    const snapshot = try out.toOwnedSlice();
    defer allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\fd_nonzero: true
        \\path_contains: true
        \\stat_present: true
        \\stat_after: false
        \\
    ).diff(snapshot, true);
}

test "permission socket read/write roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const ohsnap = @import("ohsnap");

    const req_fds = try std.posix.pipe();
    defer std.posix.close(req_fds[0]);
    defer std.posix.close(req_fds[1]);

    const request = HookRequest{
        .tool_name = "Bash",
        .tool_input = .{ .string = "ls" },
        .tool_use_id = "tool-1",
        .session_id = "session-1",
    };
    try writeRequest(allocator, req_fds[1], request);
    var parsed_req = (try readRequest(allocator, req_fds[0], std.time.milliTimestamp() + 1000)) orelse {
        return error.TestUnexpectedResult;
    };
    defer parsed_req.deinit();

    const req_summary = .{
        .tool_name = parsed_req.value.tool_name,
        .tool_use_id = parsed_req.value.tool_use_id,
        .session_id = parsed_req.value.session_id,
    };
    try (ohsnap{}).snap(@src(),
        \\core.permission_socket.test.permission socket read/write roundtrip__struct_<^\d+$>
        \\  .tool_name: []const u8
        \\    "Bash"
        \\  .tool_use_id: []const u8
        \\    "tool-1"
        \\  .session_id: []const u8
        \\    "session-1"
    ).expectEqual(req_summary);

    const resp_fds = try std.posix.pipe();
    defer std.posix.close(resp_fds[0]);
    defer std.posix.close(resp_fds[1]);

    const response = HookResponse{
        .decision = "allow",
        .reason = "ok",
    };
    try writeResponse(allocator, resp_fds[1], response);
    var parsed_resp = (try readResponse(allocator, resp_fds[0], std.time.milliTimestamp() + 1000)) orelse {
        return error.TestUnexpectedResult;
    };
    defer parsed_resp.deinit();

    const resp_summary = .{
        .decision = parsed_resp.value.decision,
        .reason = parsed_resp.value.reason,
    };
    try (ohsnap{}).snap(@src(),
        \\core.permission_socket.test.permission socket read/write roundtrip__struct_<^\d+$>
        \\  .decision: []const u8
        \\    "allow"
        \\  .reason: ?[]const u8
        \\    "ok"
    ).expectEqual(resp_summary);
}
