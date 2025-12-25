const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");

const log = std.log.scoped(.tool_proxy);

/// Tool proxy for delegating operations to Zed via ACP
///
/// When Claude CLI wants to read/write files or execute commands,
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
        callback: ?*const fn (result: std.json.Value) void = null,
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

        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try params.object.put("path", .{ .string = path });

        // Send request to Zed
        // Note: This requires bidirectional communication - agent sends request to client
        log.debug("Requesting file read: {s}", .{path});

        try self.pending_requests.put(request_id, .{ .method = "fs/read_text_file" });

        // TODO: Actually send the request
        // The current jsonrpc.Writer only supports Response and Notification,
        // we'd need to add Request support for bidirectional communication

        return request_id;
    }

    /// Request to write a file via Zed
    pub fn writeFile(self: *ToolProxy, path: []const u8, content: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try params.object.put("path", .{ .string = path });
        try params.object.put("content", .{ .string = content });

        log.debug("Requesting file write: {s}", .{path});

        try self.pending_requests.put(request_id, .{ .method = "fs/write_text_file" });

        return request_id;
    }

    /// Request to create a terminal via Zed
    pub fn createTerminal(self: *ToolProxy, command: []const u8, cwd: ?[]const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try params.object.put("command", .{ .string = command });
        if (cwd) |c| {
            try params.object.put("cwd", .{ .string = c });
        }

        log.debug("Requesting terminal: {s}", .{command});

        try self.pending_requests.put(request_id, .{ .method = "terminal/create" });

        return request_id;
    }

    /// Handle a response from Zed
    pub fn handleResponse(self: *ToolProxy, request_id: i64, result: std.json.Value) void {
        if (self.pending_requests.fetchRemove(request_id)) |entry| {
            log.debug("Received response for {s}", .{entry.value.method});
            if (entry.value.callback) |cb| {
                cb(result);
            }
        }
    }
};

// Tests
const testing = std.testing;

test "ToolProxy init/deinit" {
    var writer: jsonrpc.Writer = undefined; // Not used in this test
    var proxy = ToolProxy.init(testing.allocator, &writer);
    defer proxy.deinit();
}
