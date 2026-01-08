const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.permission_socket);

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
    std.fs.cwd().deleteFile(path) catch {};

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
    std.fs.cwd().deleteFile(path) catch {};
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
        std.fs.cwd().deleteFile(path) catch {};

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
        std.fs.cwd().deleteFile(self.path) catch {};
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

    var sock = try PermissionSocket.create(allocator, "test-session-123");

    // Verify socket was created
    try std.testing.expect(sock.fd() != 0);
    try std.testing.expect(std.mem.indexOf(u8, sock.getPath(), "test-session-123") != null);

    // Socket file should exist
    const stat = std.fs.cwd().statFile(sock.getPath()) catch null;
    try std.testing.expect(stat != null);

    // Close and verify cleanup
    const path_copy = try allocator.dupe(u8, sock.getPath());
    defer allocator.free(path_copy);

    sock.close();

    // Socket file should be removed
    const stat2 = std.fs.cwd().statFile(path_copy) catch null;
    try std.testing.expect(stat2 == null);
}
