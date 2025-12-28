const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");

const log = std.log.scoped(.tool_proxy);

// Request parameter schemas for Zed ACP
const ReadFileParams = struct {
    path: []const u8,
};

const WriteFileParams = struct {
    path: []const u8,
    content: []const u8,
};

const CreateTerminalParams = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
};

/// Tool proxy for delegating operations to Zed via ACP
///
/// When Claude Code wants to read/write files or execute commands,
/// we can intercept and delegate to Zed instead. This allows:
/// - File operations through Zed's file system
/// - Terminal execution through Zed's terminal API
/// - Better integration with editor state
pub const ToolProxy = struct {
    allocator: Allocator,
    writer: *jsonrpc.Writer,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    next_request_id: i64 = 1,

    const PendingRequest = struct {
        method: []const u8,
    };

    pub fn init(allocator: Allocator, writer: *jsonrpc.Writer) ToolProxy {
        return .{
            .allocator = allocator,
            .writer = writer,
            .pending_requests = std.AutoHashMap(i64, PendingRequest).init(allocator),
        };
    }

    pub fn deinit(self: *ToolProxy) void {
        self.pending_requests.deinit();
    }

    /// Request to read a file via Zed
    pub fn readFile(self: *ToolProxy, path: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "fs/readTextFile",
            ReadFileParams{ .path = path },
        );

        try self.pending_requests.put(request_id, .{ .method = "fs/readTextFile" });
        log.debug("Sent readTextFile request {d}: {s}", .{ request_id, path });

        return request_id;
    }

    /// Request to write a file via Zed
    pub fn writeFile(self: *ToolProxy, path: []const u8, content: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "fs/writeTextFile",
            WriteFileParams{ .path = path, .content = content },
        );

        try self.pending_requests.put(request_id, .{ .method = "fs/writeTextFile" });
        log.debug("Sent writeTextFile request {d}: {s}", .{ request_id, path });

        return request_id;
    }

    /// Request to create a terminal via Zed
    pub fn createTerminal(self: *ToolProxy, command: []const u8, cwd: ?[]const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "terminal/create",
            CreateTerminalParams{ .command = command, .cwd = cwd },
        );

        try self.pending_requests.put(request_id, .{ .method = "terminal/create" });
        log.debug("Sent terminal/create request {d}: {s}", .{ request_id, command });

        return request_id;
    }

    /// Check if a request is pending
    pub fn isPending(self: *ToolProxy, request_id: i64) bool {
        return self.pending_requests.contains(request_id);
    }

    /// Handle a response from Zed
    pub fn handleResponse(self: *ToolProxy, request_id: i64, result: std.json.Value) ?[]const u8 {
        if (self.pending_requests.fetchRemove(request_id)) |entry| {
            log.debug("Received response for {s} (id={d})", .{ entry.value.method, request_id });
            _ = result; // Caller should process result based on method
            return entry.value.method;
        }
        return null;
    }

    /// Handle an error response from Zed
    pub fn handleError(self: *ToolProxy, request_id: i64, err: jsonrpc.Error) void {
        if (self.pending_requests.fetchRemove(request_id)) |entry| {
            log.err("Request {s} (id={d}) failed: {s}", .{ entry.value.method, request_id, err.message });
        }
    }
};

// Tests
const testing = std.testing;

test "ToolProxy init/deinit" {
    var writer: jsonrpc.Writer = undefined;
    var proxy = ToolProxy.init(testing.allocator, &writer);
    defer proxy.deinit();
}

test "ToolProxy request tracking" {
    var writer: jsonrpc.Writer = undefined;
    var proxy = ToolProxy.init(testing.allocator, &writer);
    defer proxy.deinit();

    // Can't actually send requests without a real writer, but we can test tracking
    try proxy.pending_requests.put(1, .{ .method = "test" });
    try testing.expect(proxy.isPending(1));
    try testing.expect(!proxy.isPending(2));

    const method = proxy.handleResponse(1, .null);
    try testing.expectEqualStrings("test", method.?);
    try testing.expect(!proxy.isPending(1));
}
