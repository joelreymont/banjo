const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("../acp/protocol.zig");

const log = std.log.scoped(.tool_proxy);

/// Tool proxy for delegating operations to Zed via ACP
///
/// When Claude Code wants to read/write files or execute commands,
/// we can intercept and delegate to Zed instead. This allows:
/// - File operations through Zed's file system
/// - Terminal execution through Zed's terminal API
/// - Better integration with editor state
pub const ToolProxy = struct {
    allocator: Allocator,
    writer: jsonrpc.Writer,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    next_request_id: i64 = 1,

    const PendingRequest = struct {
        method: []const u8,
    };

    pub fn init(allocator: Allocator, writer: jsonrpc.Writer) ToolProxy {
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
    pub fn readFile(self: *ToolProxy, session_id: []const u8, path: []const u8, line: ?u32, limit: ?u32) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "fs/read_text_file",
            protocol.ReadTextFileRequest{
                .sessionId = session_id,
                .path = path,
                .line = line,
                .limit = limit,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "fs/read_text_file" });
        log.debug("Sent readTextFile request {d}: {s}", .{ request_id, path });

        return request_id;
    }

    /// Request to write a file via Zed
    pub fn writeFile(self: *ToolProxy, session_id: []const u8, path: []const u8, content: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "fs/write_text_file",
            protocol.WriteTextFileRequest{
                .sessionId = session_id,
                .path = path,
                .content = content,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "fs/write_text_file" });
        log.debug("Sent writeTextFile request {d}: {s}", .{ request_id, path });

        return request_id;
    }

    /// Request to create a terminal via Zed
    pub fn createTerminal(
        self: *ToolProxy,
        session_id: []const u8,
        command: []const u8,
        args: ?[]const []const u8,
        env: ?[]const protocol.EnvVariable,
        cwd: ?[]const u8,
        output_byte_limit: ?u64,
    ) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "terminal/create",
            protocol.CreateTerminalRequest{
                .sessionId = session_id,
                .command = command,
                .args = args,
                .env = env,
                .cwd = cwd,
                .outputByteLimit = output_byte_limit,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "terminal/create" });
        log.debug("Sent terminal/create request {d}: {s}", .{ request_id, command });

        return request_id;
    }

    /// Request terminal output from Zed
    pub fn terminalOutput(self: *ToolProxy, session_id: []const u8, terminal_id: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "terminal/output",
            protocol.TerminalOutputRequest{
                .sessionId = session_id,
                .terminalId = terminal_id,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "terminal/output" });
        log.debug("Sent terminal/output request {d} for terminal {s}", .{ request_id, terminal_id });
        return request_id;
    }

    /// Wait for a terminal to exit
    pub fn waitForExit(self: *ToolProxy, session_id: []const u8, terminal_id: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "terminal/wait_for_exit",
            protocol.WaitForTerminalExitRequest{
                .sessionId = session_id,
                .terminalId = terminal_id,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "terminal/wait_for_exit" });
        log.debug("Sent terminal/waitForExit request {d} for terminal {s}", .{ request_id, terminal_id });
        return request_id;
    }

    /// Kill a terminal command without releasing it
    pub fn killTerminal(self: *ToolProxy, session_id: []const u8, terminal_id: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "terminal/kill",
            protocol.TerminalKillRequest{
                .sessionId = session_id,
                .terminalId = terminal_id,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "terminal/kill" });
        log.debug("Sent terminal/kill request {d} for terminal {s}", .{ request_id, terminal_id });
        return request_id;
    }

    /// Release a terminal and free its resources
    pub fn releaseTerminal(self: *ToolProxy, session_id: []const u8, terminal_id: []const u8) !i64 {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        try self.writer.writeTypedRequest(
            .{ .number = request_id },
            "terminal/release",
            protocol.TerminalReleaseRequest{
                .sessionId = session_id,
                .terminalId = terminal_id,
            },
        );

        try self.pending_requests.put(request_id, .{ .method = "terminal/release" });
        log.debug("Sent terminal/release request {d} for terminal {s}", .{ request_id, terminal_id });
        return request_id;
    }

    /// Check if a request is pending
    pub fn isPending(self: *ToolProxy, request_id: i64) bool {
        return self.pending_requests.contains(request_id);
    }

    /// Handle a response from Zed
    pub fn handleResponse(self: *ToolProxy, request_id: i64) ?[]const u8 {
        if (self.pending_requests.fetchRemove(request_id)) |entry| {
            log.debug("Received response for {s} (id={d})", .{ entry.value.method, request_id });
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
const ohsnap = @import("ohsnap");

test "ToolProxy init/deinit" {
    const writer = jsonrpc.Writer.init(testing.allocator, std.io.null_writer.any());
    var proxy = ToolProxy.init(testing.allocator, writer);
    defer proxy.deinit();
}

test "ToolProxy request tracking" {
    const writer = jsonrpc.Writer.init(testing.allocator, std.io.null_writer.any());
    var proxy = ToolProxy.init(testing.allocator, writer);
    defer proxy.deinit();

    // Can't actually send requests without a real writer, but we can test tracking
    try proxy.pending_requests.put(1, .{ .method = "test" });
    const before_pending1 = proxy.isPending(1);
    const before_pending2 = proxy.isPending(2);

    const method = proxy.handleResponse(1);
    const method_str = method orelse "null";
    const pending_after = proxy.isPending(1);

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print(
        "pending1: {any}\npending2: {any}\nmethod: {s}\npending_after: {any}\n",
        .{ before_pending1, before_pending2, method_str, pending_after },
    );
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\pending1: true
        \\pending2: false
        \\method: test
        \\pending_after: false
        \\
    ).diff(snapshot, true);
}
