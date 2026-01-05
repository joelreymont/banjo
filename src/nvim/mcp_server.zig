const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const lockfile = @import("lockfile.zig");
const websocket = @import("websocket.zig");
const mcp_types = @import("mcp_types.zig");

const log = std.log.scoped(.mcp_server);

pub const McpServer = struct {
    allocator: Allocator,
    tcp_socket: posix.socket_t,
    mcp_client_socket: ?posix.socket_t = null,
    nvim_client_socket: ?posix.socket_t = null,
    lock_file: ?lockfile.LockFile = null,
    port: u16,
    auth_token: [36]u8,
    cwd: []const u8,

    // Tool request management
    pending_tool_requests: std.StringHashMap(PendingToolRequest),
    next_request_id: u64 = 0,

    // Selection cache for getLatestSelection (owned strings)
    last_selection: ?OwnedSelection = null,

    // Read buffers for WebSocket frames (separate per client)
    mcp_read_buffer: std.ArrayList(u8) = .empty,
    nvim_read_buffer: std.ArrayList(u8) = .empty,

    // Callback for sending tool requests to nvim
    tool_request_callback: ?*const fn (tool_name: []const u8, correlation_id: []const u8, args: ?std.json.Value) void = null,
    callback_ctx: ?*anyopaque = null,

    // Callback for nvim messages (prompt, cancel, etc.)
    nvim_message_callback: ?*const fn (ctx: *anyopaque, method: []const u8, params: ?std.json.Value) void = null,
    nvim_callback_ctx: ?*anyopaque = null,

    // Type declarations (must come after fields)
    const OwnedSelection = struct {
        text: []const u8, // owned
        file: []const u8, // owned
        range: ?mcp_types.SelectionRange,

        fn deinit(self: *const OwnedSelection, allocator: Allocator) void {
            allocator.free(self.text);
            allocator.free(self.file);
        }

        fn toResult(self: OwnedSelection) mcp_types.SelectionResult {
            return .{
                .text = self.text,
                .file = self.file,
                .range = self.range,
            };
        }
    };

    const PendingToolRequest = struct {
        correlation_id: []const u8, // owned
        mcp_request_id_json: []const u8, // owned - serialized JSON of the ID
        tool_name: []const u8, // owned
        deadline_ms: i64,

        fn deinit(self: *const PendingToolRequest, allocator: Allocator) void {
            allocator.free(self.correlation_id);
            allocator.free(self.mcp_request_id_json);
            allocator.free(self.tool_name);
        }
    };

    pub fn init(allocator: Allocator, cwd: []const u8) !*McpServer {
        // Create TCP socket
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        // Set SO_REUSEADDR
        const one: u32 = 1;
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&one));

        // Bind to random port on localhost
        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        try posix.bind(sock, &addr.any, addr.getOsSockLen());
        try posix.listen(sock, 1);

        // Get assigned port
        var bound_addr: std.net.Address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len: posix.socklen_t = bound_addr.getOsSockLen();
        try posix.getsockname(sock, &bound_addr.any, &addr_len);
        const port = bound_addr.getPort();

        // Generate auth token
        var auth_token: [36]u8 = undefined;
        lockfile.generateUuidV4(&auth_token);

        const self = try allocator.create(McpServer);
        self.* = McpServer{
            .allocator = allocator,
            .tcp_socket = sock,
            .port = port,
            .auth_token = auth_token,
            .cwd = cwd,
            .pending_tool_requests = std.StringHashMap(PendingToolRequest).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *McpServer) void {
        self.stop();
        // Clean up any remaining pending requests
        var iter = self.pending_tool_requests.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_tool_requests.deinit();
        self.mcp_read_buffer.deinit(self.allocator);
        self.nvim_read_buffer.deinit(self.allocator);
        // Free owned selection data
        if (self.last_selection) |sel| {
            sel.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    pub fn start(self: *McpServer) !void {
        // Create lock file
        self.lock_file = try lockfile.create(
            self.allocator,
            self.port,
            self.cwd,
            &self.auth_token,
        );
        log.info("MCP server listening on port {d}", .{self.port});
    }

    pub fn stop(self: *McpServer) void {
        // Send close frame to MCP client if connected
        if (self.mcp_client_socket) |sock| {
            const close_frame = websocket.encodeFrame(self.allocator, .close, "") catch null;
            if (close_frame) |frame| {
                _ = posix.write(sock, frame) catch {};
                self.allocator.free(frame);
            }
            posix.close(sock);
            self.mcp_client_socket = null;
        }

        // Send close frame to nvim client if connected
        if (self.nvim_client_socket) |sock| {
            const close_frame = websocket.encodeFrame(self.allocator, .close, "") catch null;
            if (close_frame) |frame| {
                _ = posix.write(sock, frame) catch {};
                self.allocator.free(frame);
            }
            posix.close(sock);
            self.nvim_client_socket = null;
        }

        // Delete lock file
        if (self.lock_file) |*lock| {
            lock.deinit();
            self.lock_file = null;
        }

        posix.close(self.tcp_socket);
    }

    pub fn getPort(self: *McpServer) u16 {
        return self.port;
    }

    /// Poll for events with timeout in milliseconds.
    /// Returns true if should continue polling.
    pub fn poll(self: *McpServer, timeout_ms: i32) !bool {
        var fds: [3]posix.pollfd = undefined;
        var nfds: usize = 0;

        // Always poll TCP accept socket
        fds[nfds] = .{ .fd = self.tcp_socket, .events = posix.POLL.IN, .revents = 0 };
        nfds += 1;

        // Poll MCP client socket if connected
        if (self.mcp_client_socket) |sock| {
            fds[nfds] = .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        // Poll nvim client socket if connected
        if (self.nvim_client_socket) |sock| {
            fds[nfds] = .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        const ready = try posix.poll(fds[0..nfds], timeout_ms);
        if (ready == 0) {
            // Timeout - check for expired requests
            self.checkTimeouts();
            return true;
        }

        // Handle events
        for (fds[0..nfds]) |fd| {
            if (fd.revents & posix.POLL.IN != 0) {
                if (fd.fd == self.tcp_socket) {
                    self.acceptConnection() catch |err| {
                        log.warn("Accept failed: {}", .{err});
                    };
                } else if (self.mcp_client_socket != null and fd.fd == self.mcp_client_socket.?) {
                    self.handleMcpClientMessage() catch |err| {
                        log.warn("MCP client message failed: {}", .{err});
                        self.closeMcpClient();
                    };
                } else if (self.nvim_client_socket != null and fd.fd == self.nvim_client_socket.?) {
                    self.handleNvimClientMessage() catch |err| {
                        log.warn("Nvim client message failed: {}", .{err});
                        self.closeNvimClient();
                    };
                }
            }
            // Guard: socket may have been closed in error handler above
            if (fd.revents & posix.POLL.HUP != 0 or fd.revents & posix.POLL.ERR != 0) {
                if (self.mcp_client_socket != null and fd.fd == self.mcp_client_socket.?) {
                    log.info("MCP client disconnected", .{});
                    self.closeMcpClient();
                }
                if (self.nvim_client_socket != null and fd.fd == self.nvim_client_socket.?) {
                    log.info("Nvim client disconnected", .{});
                    self.closeNvimClient();
                }
            }
        }

        return true;
    }

    fn closeMcpClient(self: *McpServer) void {
        if (self.mcp_client_socket) |sock| {
            posix.close(sock);
            self.mcp_client_socket = null;
            self.mcp_read_buffer.clearRetainingCapacity();
        }
    }

    fn closeNvimClient(self: *McpServer) void {
        if (self.nvim_client_socket) |sock| {
            posix.close(sock);
            self.nvim_client_socket = null;
            self.nvim_read_buffer.clearRetainingCapacity();
        }
    }

    fn acceptConnection(self: *McpServer) !void {
        const client = try posix.accept(self.tcp_socket, null, null, 0);
        errdefer posix.close(client);

        // Perform WebSocket handshake and determine client type
        const client_kind = websocket.performHandshakeWithPath(self.allocator, client, &self.auth_token) catch |err| {
            log.warn("WebSocket handshake failed: {}", .{err});
            posix.close(client);
            return;
        };

        switch (client_kind) {
            .mcp => {
                // Close existing MCP client if any
                if (self.mcp_client_socket) |old| {
                    log.info("Closing existing MCP client connection", .{});
                    posix.close(old);
                }
                self.mcp_client_socket = client;
                self.mcp_read_buffer.clearRetainingCapacity();
                log.info("Claude CLI connected", .{});
            },
            .nvim => {
                // Close existing nvim client if any
                if (self.nvim_client_socket) |old| {
                    log.info("Closing existing nvim client connection", .{});
                    posix.close(old);
                }
                self.nvim_client_socket = client;
                self.nvim_read_buffer.clearRetainingCapacity();
                log.info("Neovim connected", .{});
            },
        }
    }

    fn handleMcpClientMessage(self: *McpServer) !void {
        const client = self.mcp_client_socket orelse return;

        // Read available data into buffer
        var temp_buf: [4096]u8 = undefined;
        const n = posix.read(client, &temp_buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;

        try self.mcp_read_buffer.appendSlice(self.allocator, temp_buf[0..n]);

        // Try to parse complete frames
        while (self.mcp_read_buffer.items.len >= 2) {
            const result = websocket.parseFrame(self.mcp_read_buffer.items) catch |err| switch (err) {
                error.NeedMoreData => break,
                error.ReservedOpcode => {
                    log.warn("Received frame with reserved opcode, closing connection", .{});
                    posix.close(client);
                    self.mcp_client_socket = null;
                    return;
                },
                else => return err,
            };

            // Process frame
            switch (result.frame.opcode) {
                .text => {
                    try self.handleMcpJsonRpcMessage(result.frame.payload);
                },
                .ping => {
                    // Respond with pong
                    const pong = try websocket.encodeFrame(self.allocator, .pong, result.frame.payload);
                    defer self.allocator.free(pong);
                    _ = try posix.write(client, pong);
                },
                .close => {
                    log.info("MCP client sent close frame", .{});
                    self.closeMcpClient();
                    return;
                },
                else => {},
            }

            // Remove consumed bytes
            const remaining = self.mcp_read_buffer.items[result.consumed..];
            std.mem.copyForwards(u8, self.mcp_read_buffer.items[0..remaining.len], remaining);
            self.mcp_read_buffer.shrinkRetainingCapacity(remaining.len);
        }
    }

    fn handleNvimClientMessage(self: *McpServer) !void {
        const client = self.nvim_client_socket orelse return;

        // Read available data into buffer
        var temp_buf: [4096]u8 = undefined;
        const n = posix.read(client, &temp_buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;

        try self.nvim_read_buffer.appendSlice(self.allocator, temp_buf[0..n]);

        // Try to parse complete frames
        while (self.nvim_read_buffer.items.len >= 2) {
            const result = websocket.parseFrame(self.nvim_read_buffer.items) catch |err| switch (err) {
                error.NeedMoreData => break,
                error.ReservedOpcode => {
                    log.warn("Received nvim frame with reserved opcode, closing connection", .{});
                    self.closeNvimClient();
                    return;
                },
                else => return err,
            };

            // Process frame
            switch (result.frame.opcode) {
                .text => {
                    self.handleNvimJsonRpcMessage(result.frame.payload);
                },
                .ping => {
                    // Respond with pong
                    const pong = try websocket.encodeFrame(self.allocator, .pong, result.frame.payload);
                    defer self.allocator.free(pong);
                    _ = try posix.write(client, pong);
                },
                .close => {
                    log.info("Nvim client sent close frame", .{});
                    self.closeNvimClient();
                    return;
                },
                else => {},
            }

            // Remove consumed bytes
            const remaining = self.nvim_read_buffer.items[result.consumed..];
            std.mem.copyForwards(u8, self.nvim_read_buffer.items[0..remaining.len], remaining);
            self.nvim_read_buffer.shrinkRetainingCapacity(remaining.len);
        }
    }

    fn handleNvimJsonRpcMessage(self: *McpServer, payload: []const u8) void {
        const parsed = std.json.parseFromSlice(mcp_types.JsonRpcRequest, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            log.warn("Failed to parse nvim JSON-RPC message", .{});
            return;
        };
        defer parsed.deinit();

        const req = parsed.value;

        // Forward to handler via callback
        if (self.nvim_message_callback) |callback| {
            if (self.nvim_callback_ctx) |ctx| {
                callback(ctx, req.method, req.params);
            }
        }
    }

    fn handleMcpJsonRpcMessage(self: *McpServer, payload: []const u8) !void {
        const parsed = std.json.parseFromSlice(mcp_types.JsonRpcRequest, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.sendMcpError(null, mcp_types.ErrorCode.ParseError, "Parse error");
            return;
        };
        defer parsed.deinit();

        const req = parsed.value;
        const method = req.method;
        const id = req.id;

        // Dispatch by method
        const method_map = std.StaticStringMap(MethodKind).initComptime(.{
            .{ mcp_types.Method.Initialize, .initialize },
            .{ mcp_types.Method.Initialized, .initialized },
            .{ mcp_types.Method.ToolsList, .tools_list },
            .{ mcp_types.Method.ToolsCall, .tools_call },
        });

        const kind = method_map.get(method) orelse {
            if (id != null) {
                try self.sendMcpError(id, mcp_types.ErrorCode.MethodNotFound, "Method not found");
            }
            return;
        };

        switch (kind) {
            .initialize => try self.handleInitialize(id),
            .initialized => {}, // Notification, no response needed
            .tools_list => try self.handleToolsList(id),
            .tools_call => try self.handleToolsCall(id, req.params),
        }
    }

    const MethodKind = enum {
        initialize,
        initialized,
        tools_list,
        tools_call,
    };

    fn handleInitialize(self: *McpServer, id: ?std.json.Value) !void {
        const result = mcp_types.InitializeResult{};
        try self.sendResult(id, result);
    }

    fn handleToolsList(self: *McpServer, id: ?std.json.Value) !void {
        const tools = mcp_types.getToolDefinitions();
        const result = mcp_types.ToolsListResult{ .tools = tools };
        try self.sendResult(id, result);
    }

    fn handleToolsCall(self: *McpServer, id: ?std.json.Value, params: ?std.json.Value) !void {
        if (id == null) return; // tools/call requires an id

        const tool_params = params orelse {
            try self.sendMcpError(id, mcp_types.ErrorCode.InvalidParams, "Missing params");
            return;
        };

        // Parse tool name and arguments
        const parsed = std.json.parseFromValue(mcp_types.ToolsCallParams, self.allocator, tool_params, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.sendMcpError(id, mcp_types.ErrorCode.InvalidParams, "Invalid tool call params");
            return;
        };
        defer parsed.deinit();

        const tool_name = parsed.value.name;
        const tool_args = parsed.value.arguments;

        // Check if this is a local tool (can be handled without Lua)
        if (self.handleLocalTool(id, tool_name, tool_args)) |_| {
            return; // Handled locally
        } else |_| {}

        // Forward to Lua via callback
        if (self.tool_request_callback) |callback| {
            const correlation_id = try self.generateCorrelationId();
            errdefer self.allocator.free(correlation_id);

            // Serialize ID to owned string
            const id_json = try serializeToJson(self.allocator, id.?);
            errdefer self.allocator.free(id_json);

            // Dupe tool name
            const owned_tool_name = try self.allocator.dupe(u8, tool_name);
            errdefer self.allocator.free(owned_tool_name);

            try self.pending_tool_requests.put(correlation_id, .{
                .correlation_id = correlation_id,
                .mcp_request_id_json = id_json,
                .tool_name = owned_tool_name,
                .deadline_ms = std.time.milliTimestamp() + TOOL_REQUEST_TIMEOUT_MS,
            });
            callback(owned_tool_name, correlation_id, tool_args);
        } else {
            try self.sendToolError(id, "Tool handler not available");
        }
    }

    const TOOL_REQUEST_TIMEOUT_MS: i64 = 30_000;

    fn handleLocalTool(self: *McpServer, id: ?std.json.Value, tool_name: []const u8, args: ?std.json.Value) !void {
        const local_tools = std.StaticStringMap(LocalTool).initComptime(.{
            .{ "getWorkspaceFolders", .get_workspace_folders },
            .{ "getLatestSelection", .get_latest_selection },
            .{ "executeCode", .execute_code },
        });

        const tool = local_tools.get(tool_name) orelse return error.NotLocalTool;

        _ = args;
        switch (tool) {
            .get_workspace_folders => {
                const folders = [_][]const u8{self.cwd};
                const result = mcp_types.WorkspaceFoldersResult{ .folders = &folders };
                const json_str = try serializeToJson(self.allocator, result);
                defer self.allocator.free(json_str);
                try self.sendToolResultOptional(id, json_str);
            },
            .get_latest_selection => {
                const result = if (self.last_selection) |sel|
                    sel.toResult()
                else
                    mcp_types.SelectionResult{};
                const json_str = try serializeToJson(self.allocator, result);
                defer self.allocator.free(json_str);
                try self.sendToolResultOptional(id, json_str);
            },
            .execute_code => {
                try self.sendToolError(id, "Jupyter kernel execution not supported in Neovim");
            },
        }
    }

    fn serializeToJson(allocator: Allocator, value: anytype) ![]u8 {
        var out: std.io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try jw.write(value);
        return out.toOwnedSlice();
    }

    const LocalTool = enum {
        get_workspace_folders,
        get_latest_selection,
        execute_code,
    };

    pub fn handleToolResponse(self: *McpServer, correlation_id: []const u8, result: ?[]const u8, err: ?[]const u8) !void {
        // Use fetchRemove to atomically remove and get the entry
        // This avoids dangling pointer issues since the key IS the correlation_id in the value
        const kv = self.pending_tool_requests.fetchRemove(correlation_id) orelse {
            log.warn("Unknown correlation id: {s}", .{correlation_id});
            return;
        };
        const pending = kv.value;
        defer pending.deinit(self.allocator);

        // Parse the ID back from JSON
        var id_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, pending.mcp_request_id_json, .{}) catch {
            log.err("Failed to parse stored request ID for {s}", .{correlation_id});
            return;
        };
        defer id_parsed.deinit();

        if (err) |error_msg| {
            try self.sendToolErrorWithId(id_parsed.value, error_msg);
        } else if (result) |r| {
            try self.sendToolResult(id_parsed.value, r);
        } else {
            try self.sendToolErrorWithId(id_parsed.value, "No result");
        }
    }

    pub fn updateSelection(self: *McpServer, selection: mcp_types.SelectionResult) !void {
        // Free previous selection if any
        if (self.last_selection) |prev| {
            prev.deinit(self.allocator);
        }

        // Duplicate strings to take ownership
        const text = try self.allocator.dupe(u8, selection.text);
        errdefer self.allocator.free(text);
        const file = try self.allocator.dupe(u8, selection.file);

        self.last_selection = .{
            .text = text,
            .file = file,
            .range = selection.range,
        };
    }

    fn generateCorrelationId(self: *McpServer) ![]const u8 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return try std.fmt.allocPrint(self.allocator, "tool-{d}", .{id});
    }

    fn checkTimeouts(self: *McpServer) void {
        const now = std.time.milliTimestamp();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        // Collect keys that have timed out (dupe to avoid use-after-free during removal)
        var iter = self.pending_tool_requests.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.deadline_ms < now) {
                const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch |err| {
                    log.err("Failed to allocate key copy for timeout removal: {}", .{err});
                    continue;
                };
                to_remove.append(self.allocator, key_copy) catch |err| {
                    self.allocator.free(key_copy);
                    log.err("Failed to track timed-out request for removal: {}", .{err});
                    continue;
                };
            }
        }

        for (to_remove.items) |key_copy| {
            defer self.allocator.free(key_copy);

            // Use fetchRemove to atomically remove and get ownership of key/value
            if (self.pending_tool_requests.fetchRemove(key_copy)) |kv| {
                const pending = kv.value;
                // Note: kv.key == pending.correlation_id (same allocation)
                // pending.deinit() frees correlation_id, so don't free kv.key separately

                // Parse the ID back from JSON and send timeout error
                var id_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, pending.mcp_request_id_json, .{}) catch {
                    pending.deinit(self.allocator);
                    continue;
                };
                defer id_parsed.deinit();

                self.sendToolErrorWithId(id_parsed.value, "Tool request timed out") catch {};
                pending.deinit(self.allocator);
            }
        }
    }

    fn sendResult(self: *McpServer, id: ?std.json.Value, result: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const response = mcp_types.JsonRpcResponse{
            .id = id,
            .result = try jsonValueFromTyped(arena.allocator(), result),
        };
        try self.sendMcpTypedResponse(response);
    }

    fn sendToolResult(self: *McpServer, id: std.json.Value, json_text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // MCP tool results must be wrapped in content array
        const content = [_]mcp_types.ContentItem{
            .{ .text = json_text },
        };
        const tool_result = mcp_types.ToolCallResult{ .content = &content };
        const response = mcp_types.JsonRpcResponse{
            .id = id,
            .result = try jsonValueFromTyped(arena.allocator(), tool_result),
        };
        try self.sendMcpTypedResponse(response);
    }

    fn sendToolResultOptional(self: *McpServer, id: ?std.json.Value, json_text: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // MCP tool results must be wrapped in content array
        const content = [_]mcp_types.ContentItem{
            .{ .text = json_text },
        };
        const tool_result = mcp_types.ToolCallResult{ .content = &content };
        const response = mcp_types.JsonRpcResponse{
            .id = id,
            .result = try jsonValueFromTyped(arena.allocator(), tool_result),
        };
        try self.sendMcpTypedResponse(response);
    }

    fn sendToolError(self: *McpServer, id: ?std.json.Value, message: []const u8) !void {
        try self.sendToolErrorImpl(id, message);
    }

    fn sendToolErrorWithId(self: *McpServer, id: std.json.Value, message: []const u8) !void {
        try self.sendToolErrorImpl(id, message);
    }

    fn sendToolErrorImpl(self: *McpServer, id: ?std.json.Value, message: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        // MCP errors are returned as isError content per spec
        const content = [_]mcp_types.ContentItem{
            .{ .text = message },
        };
        const error_result = ToolErrorResult{
            .content = &content,
            .isError = true,
        };

        const response = mcp_types.JsonRpcResponse{
            .id = id,
            .result = try jsonValueFromTyped(arena.allocator(), error_result),
        };
        try self.sendMcpTypedResponse(response);
    }

    const ToolErrorResult = struct {
        content: []const mcp_types.ContentItem,
        isError: bool,
    };

    fn sendMcpError(self: *McpServer, id: ?std.json.Value, code: i32, message: []const u8) !void {
        const response = mcp_types.JsonRpcResponse{
            .id = id,
            .@"error" = .{
                .code = code,
                .message = message,
            },
        };
        try self.sendMcpTypedResponse(response);
    }

    fn sendMcpTypedResponse(self: *McpServer, response: mcp_types.JsonRpcResponse) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        try jw.write(response);

        const buf = try out.toOwnedSlice();
        defer self.allocator.free(buf);
        try self.sendMcpWebSocketMessage(buf);
    }

    fn jsonValueFromTyped(allocator: Allocator, value: anytype) !std.json.Value {
        var out: std.io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        var jw: std.json.Stringify = .{ .writer = &out.writer };
        try jw.write(value);

        const json_str = try out.toOwnedSlice();
        defer allocator.free(json_str);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        // Don't deinit - caller owns the value
        return parsed.value;
    }

    fn sendMcpWebSocketMessage(self: *McpServer, message: []const u8) !void {
        const client = self.mcp_client_socket orelse return error.NotConnected;

        const frame = try websocket.encodeFrame(self.allocator, .text, message);
        defer self.allocator.free(frame);

        _ = try posix.write(client, frame);
    }

    /// Send a JSON-RPC notification to the nvim client
    pub fn sendNvimNotification(self: *McpServer, method: []const u8, params: anytype) !void {
        const client = self.nvim_client_socket orelse return error.NotConnected;

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };

        // Build notification structure
        const T = @TypeOf(params);
        if (T == @TypeOf(.{})) {
            try jw.write(.{
                .jsonrpc = "2.0",
                .method = method,
            });
        } else {
            // Serialize params to json.Value first
            var param_out: std.io.Writer.Allocating = .init(self.allocator);
            defer param_out.deinit();
            var param_jw: std.json.Stringify = .{
                .writer = &param_out.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            try param_jw.write(params);
            const param_json = try param_out.toOwnedSlice();
            defer self.allocator.free(param_json);

            var param_parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, param_json, .{});
            defer param_parsed.deinit();

            try jw.write(.{
                .jsonrpc = "2.0",
                .method = method,
                .params = param_parsed.value,
            });
        }

        const buf = try out.toOwnedSlice();
        defer self.allocator.free(buf);

        const frame = try websocket.encodeFrame(self.allocator, .text, buf);
        defer self.allocator.free(frame);

        _ = try posix.write(client, frame);
    }

    /// Check if nvim client is connected
    pub fn isNvimConnected(self: *McpServer) bool {
        return self.nvim_client_socket != null;
    }
};

// Tests
const testing = std.testing;

test "McpServer init and deinit" {
    const server = try McpServer.init(testing.allocator, "/tmp");
    defer server.deinit();

    try testing.expect(server.port > 0);
    try testing.expectEqual(@as(?posix.socket_t, null), server.mcp_client_socket);
    try testing.expectEqual(@as(?posix.socket_t, null), server.nvim_client_socket);
}

test "McpServer port binding" {
    const server1 = try McpServer.init(testing.allocator, "/tmp");
    defer server1.deinit();

    const server2 = try McpServer.init(testing.allocator, "/tmp");
    defer server2.deinit();

    // Both should get different ports
    try testing.expect(server1.port != server2.port);
}
