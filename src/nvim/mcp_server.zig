const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const lockfile = @import("lockfile.zig");
const websocket = @import("websocket.zig");
const mcp_types = @import("mcp_types.zig");
const constants = @import("../core/constants.zig");
const jsonrpc = @import("../jsonrpc.zig");
const config = @import("config");

const log = std.log.scoped(.mcp_server);
const debug_log = @import("../util/debug_log.zig");
const json_util = @import("../util/json.zig");
const byte_queue = @import("../util/byte_queue.zig");

const max_pending_handshakes: usize = 8;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    debug_log.write("MCP", fmt, args);
}

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
    mcp_read_buffer: byte_queue.ByteQueue = .{},
    nvim_read_buffer: byte_queue.ByteQueue = .{},
    pending_handshakes: std.AutoHashMap(posix.socket_t, PendingHandshake),

    // Mutex for socket operations (protects nvim_client_socket, mcp_client_socket)
    socket_mutex: std.Thread.Mutex = .{},

    // Mutex for poll operations (ensures single-threaded polling)
    poll_mutex: std.Thread.Mutex = .{},

    // Callback for sending tool requests to nvim
    tool_request_callback: ?*const fn (ctx: *anyopaque, tool_name: []const u8, correlation_id: []const u8, args: ?std.json.Value) void = null,
    tool_callback_ctx: ?*anyopaque = null,

    // Callback for nvim messages (prompt, cancel, etc.)
    nvim_message_callback: ?*const fn (ctx: *anyopaque, method: []const u8, params: ?std.json.Value) void = null,
    nvim_callback_ctx: ?*anyopaque = null,

    // Callback for nvim connection (send initial state)
    nvim_connect_callback: ?*const fn (ctx: *anyopaque) void = null,

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

    const PendingHandshake = struct {
        buffer: std.ArrayListUnmanaged(u8) = .empty,
        deadline_ms: i64,

        fn deinit(self: *PendingHandshake, allocator: Allocator) void {
            self.buffer.deinit(allocator);
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
            .pending_handshakes = std.AutoHashMap(posix.socket_t, PendingHandshake).init(allocator),
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
        self.closePendingHandshakes();
        self.pending_handshakes.deinit();
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

    fn closeSocket(self: *McpServer, socket_ptr: *?posix.socket_t, name: []const u8) void {
        const sock = socket_ptr.* orelse return;
        const close_frame = websocket.encodeFrame(self.allocator, .close, "") catch |err| blk: {
            log.debug("Failed to encode close frame for {s} client: {}", .{ name, err });
            break :blk null;
        };
        if (close_frame) |frame| {
            _ = posix.write(sock, frame) catch |err| {
                log.debug("Failed to send close frame to {s} client: {}", .{ name, err });
            };
            self.allocator.free(frame);
        }
        posix.close(sock);
        socket_ptr.* = null;
    }

    pub fn stop(self: *McpServer) void {
        self.closeSocket(&self.mcp_client_socket, "MCP");
        self.closeSocket(&self.nvim_client_socket, "nvim");

        // Delete lock file
        if (self.lock_file) |*lock| {
            lock.deinit();
            self.lock_file = null;
        }

        self.closePendingHandshakes();
        posix.close(self.tcp_socket);
    }

    pub fn getPort(self: *McpServer) u16 {
        return self.port;
    }

    /// Poll for events with timeout in milliseconds.
    /// Returns true if should continue polling.
    pub fn poll(self: *McpServer, timeout_ms: i32) !bool {
        self.poll_mutex.lock();
        defer self.poll_mutex.unlock();

        var fds: [max_pending_handshakes + 3]posix.pollfd = undefined;
        var nfds: usize = 0;

        const can_accept = self.pending_handshakes.count() < max_pending_handshakes;
        if (can_accept) {
            fds[nfds] = .{ .fd = self.tcp_socket, .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

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

        if (self.pending_handshakes.count() > 0) {
            var iter = self.pending_handshakes.iterator();
            while (iter.next()) |entry| {
                if (nfds >= fds.len) break;
                fds[nfds] = .{ .fd = entry.key_ptr.*, .events = posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }

        const ready = try posix.poll(fds[0..nfds], timeout_ms);
        if (ready == 0) {
            // Timeout - still check timeouts and handshakes
            self.checkTimeouts();
            self.expirePendingHandshakes(std.time.milliTimestamp());
            return true;
        }
        debugLog("poll: ready={d}, nfds={d}, nvim_connected={}", .{ ready, nfds, self.nvim_client_socket != null });

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
                    debugLog("poll: nvim socket has data", .{});
                    self.handleNvimClientMessage() catch |err| {
                        log.warn("Nvim client message failed: {}", .{err});
                        self.closeNvimClient();
                    };
                } else if (self.pending_handshakes.getPtr(fd.fd)) |pending| {
                    self.handlePendingHandshake(fd.fd, pending);
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
                if (self.pending_handshakes.contains(fd.fd)) {
                    log.info("Handshake client disconnected", .{});
                    self.closePendingHandshake(fd.fd);
                }
            }
        }

        // Check timeouts unconditionally (not just on poll timeout)
        self.checkTimeouts();
        self.expirePendingHandshakes(std.time.milliTimestamp());
        return true;
    }

    fn closeMcpClient(self: *McpServer) void {
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        if (self.mcp_client_socket) |sock| {
            posix.close(sock);
            self.mcp_client_socket = null;
            self.mcp_read_buffer.clear();
        }
    }

    fn closeNvimClient(self: *McpServer) void {
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        if (self.nvim_client_socket) |sock| {
            posix.close(sock);
            self.nvim_client_socket = null;
            self.nvim_read_buffer.clear();
        }
    }

    fn closePendingHandshakes(self: *McpServer) void {
        var iter = self.pending_handshakes.iterator();
        while (iter.next()) |entry| {
            posix.close(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_handshakes.clearRetainingCapacity();
    }

    fn closePendingHandshake(self: *McpServer, fd: posix.socket_t) void {
        if (self.pending_handshakes.fetchRemove(fd)) |entry| {
            posix.close(entry.key);
            var handshake = entry.value;
            handshake.deinit(self.allocator);
        } else {
            posix.close(fd);
        }
    }

    fn setNonBlocking(fd: posix.socket_t) !void {
        var flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");
        _ = try posix.fcntl(fd, posix.F.SETFL, flags);
    }

    fn setBlocking(fd: posix.socket_t) !void {
        var flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        const nonblock_bit: @TypeOf(flags) = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
        flags &= ~nonblock_bit;
        _ = try posix.fcntl(fd, posix.F.SETFL, flags);
    }

    fn queueHandshake(self: *McpServer, client: posix.socket_t) !void {
        if (self.pending_handshakes.count() >= max_pending_handshakes) {
            return error.TooManyPendingHandshakes;
        }

        try setNonBlocking(client);

        const deadline = std.time.milliTimestamp() + constants.websocket_handshake_timeout_ms;
        try self.pending_handshakes.put(client, .{ .deadline_ms = deadline });
    }

    fn finishHandshake(
        self: *McpServer,
        client_kind: websocket.ClientKind,
        client: posix.socket_t,
        remainder: []const u8,
    ) !void {
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();

        switch (client_kind) {
            .mcp => {
                if (self.mcp_client_socket) |old| {
                    log.info("Closing existing MCP client connection", .{});
                    posix.close(old);
                }
                self.mcp_client_socket = client;
                self.mcp_read_buffer.clear();
                if (remainder.len > 0) {
                    try self.mcp_read_buffer.append(self.allocator, remainder);
                }
                log.info("Claude CLI connected", .{});
            },
            .nvim => {
                if (self.nvim_client_socket) |old| {
                    log.info("Closing existing nvim client connection", .{});
                    posix.close(old);
                }
                self.nvim_client_socket = client;
                self.nvim_read_buffer.clear();
                if (remainder.len > 0) {
                    try self.nvim_read_buffer.append(self.allocator, remainder);
                }
                log.info("Neovim connected", .{});
                debugLog("nvim_client_socket set to fd={d}", .{client});

                // Notify handler to send initial state
                if (self.nvim_connect_callback) |cb| {
                    if (self.nvim_callback_ctx) |ctx| {
                        cb(ctx);
                    }
                }
            },
        }
    }

    fn handlePendingHandshake(self: *McpServer, fd: posix.socket_t, pending: *PendingHandshake) void {
        const now = std.time.milliTimestamp();
        if (pending.deadline_ms <= now) {
            log.warn("Handshake timed out for fd={d}", .{fd});
            self.closePendingHandshake(fd);
            return;
        }

        var temp_buf: [1024]u8 = undefined;
        while (true) {
            const n = posix.read(fd, &temp_buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    log.warn("Handshake read failed: {}", .{err});
                    self.closePendingHandshake(fd);
                    return;
                },
            };
            if (n == 0) {
                log.info("Handshake connection closed", .{});
                self.closePendingHandshake(fd);
                return;
            }
            pending.buffer.appendSlice(self.allocator, temp_buf[0..n]) catch |err| {
                log.warn("Handshake buffer append failed: {}", .{err});
                self.closePendingHandshake(fd);
                return;
            };
            if (pending.buffer.items.len > websocket.max_handshake_bytes) {
                log.warn("Handshake headers too large", .{});
                self.closePendingHandshake(fd);
                return;
            }
        }

        const parsed = websocket.tryParseHandshake(self.allocator, pending.buffer.items) catch |err| {
            log.warn("Handshake parse failed: {}", .{err});
            self.closePendingHandshake(fd);
            return;
        } orelse return;
        defer websocket.deinitHandshakeResult(self.allocator, &parsed.result);

        setBlocking(fd) catch |err| {
            log.warn("Failed to set blocking for handshake: {}", .{err});
            self.closePendingHandshake(fd);
            return;
        };

        const client_kind = websocket.completeHandshake(fd, parsed.result, self.auth_token[0..]) catch |err| {
            log.warn("WebSocket handshake failed: {}", .{err});
            self.closePendingHandshake(fd);
            return;
        };

        const remainder = pending.buffer.items[parsed.header_end..];
        self.finishHandshake(client_kind, fd, remainder) catch |err| {
            log.warn("Failed to finalize handshake: {}", .{err});
            self.closePendingHandshake(fd);
            return;
        };

        pending.deinit(self.allocator);
        _ = self.pending_handshakes.remove(fd);
    }

    fn expirePendingHandshakes(self: *McpServer, now_ms: i64) void {
        if (self.pending_handshakes.count() == 0) return;
        var to_remove: std.ArrayListUnmanaged(posix.socket_t) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.pending_handshakes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.deadline_ms <= now_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch |err| {
                    log.warn("Failed to track expired handshake for removal: {}", .{err});
                    continue;
                };
            }
        }

        for (to_remove.items) |fd| {
            log.warn("Handshake timed out for fd={d}", .{fd});
            self.closePendingHandshake(fd);
        }
    }

    fn acceptConnection(self: *McpServer) !void {
        const client = try posix.accept(self.tcp_socket, null, null, 0);
        errdefer posix.close(client);
        try self.queueHandshake(client);
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

        try self.mcp_read_buffer.append(self.allocator, temp_buf[0..n]);

        // Try to parse complete frames
        while (self.mcp_read_buffer.len() >= 2) {
            const buf = self.mcp_read_buffer.slice();
            const result = websocket.parseFrame(buf) catch |err| switch (err) {
                error.NeedMoreData => break,
                error.ReservedOpcode => {
                    log.warn("Received frame with reserved opcode, closing connection", .{});
                    self.closeMcpClient();
                    return;
                },
                error.UnmaskedFrame => {
                    log.warn("Received unmasked MCP frame, closing connection", .{});
                    self.closeMcpClient();
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
                    self.socket_mutex.lock();
                    defer self.socket_mutex.unlock();
                    const sock = self.mcp_client_socket orelse return error.NotConnected;
                    _ = try posix.write(sock, pong);
                },
                .close => {
                    log.info("MCP client sent close frame", .{});
                    self.closeMcpClient();
                    return;
                },
                else => {},
            }

            self.mcp_read_buffer.consume(result.consumed);
        }
    }

    fn handleNvimClientMessage(self: *McpServer) !void {
        debugLog("handleNvimClientMessage: entry", .{});
        const client = self.nvim_client_socket orelse return;

        // Read available data into buffer
        var temp_buf: [4096]u8 = undefined;
        const n = posix.read(client, &temp_buf) catch |err| switch (err) {
            error.WouldBlock => {
                debugLog("handleNvimClientMessage: WouldBlock", .{});
                return;
            },
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        debugLog("handleNvimClientMessage: read {d} bytes", .{n});

        try self.nvim_read_buffer.append(self.allocator, temp_buf[0..n]);

        // Try to parse complete frames
        while (self.nvim_read_buffer.len() >= 2) {
            const buf = self.nvim_read_buffer.slice();
            const result = websocket.parseFrame(buf) catch |err| switch (err) {
                error.NeedMoreData => break,
                error.ReservedOpcode => {
                    log.warn("Received nvim frame with reserved opcode, closing connection", .{});
                    self.closeNvimClient();
                    return;
                },
                error.UnmaskedFrame => {
                    log.warn("Received unmasked nvim frame, closing connection", .{});
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
                    self.socket_mutex.lock();
                    defer self.socket_mutex.unlock();
                    const sock = self.nvim_client_socket orelse return error.NotConnected;
                    _ = try posix.write(sock, pong);
                },
                .close => {
                    log.info("Nvim client sent close frame", .{});
                    self.closeNvimClient();
                    return;
                },
                else => {},
            }

            self.nvim_read_buffer.consume(result.consumed);
        }
    }

    fn handleNvimJsonRpcMessage(self: *McpServer, payload: []const u8) void {
        debugLog("handleNvimJsonRpcMessage: payload={d} bytes", .{payload.len});
        const parsed = std.json.parseFromSlice(mcp_types.JsonRpcRequest, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            log.warn("Failed to parse nvim JSON-RPC message", .{});
            return;
        };
        debugLog("handleNvimJsonRpcMessage: method={s}", .{parsed.value.method});
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

        // Forward to nvim via callback
        if (self.tool_request_callback) |callback| {
            const ctx = self.tool_callback_ctx orelse {
                try self.sendToolError(id, "Tool callback context not set");
                return;
            };
            const correlation_id = try self.generateCorrelationId();
            errdefer self.allocator.free(correlation_id);

            // Serialize ID to owned string
            const id_json = try json_util.serializeToJson(self.allocator, id.?);
            errdefer self.allocator.free(id_json);

            // Dupe tool name
            const owned_tool_name = try self.allocator.dupe(u8, tool_name);
            errdefer self.allocator.free(owned_tool_name);

            try self.pending_tool_requests.put(correlation_id, .{
                .correlation_id = correlation_id,
                .mcp_request_id_json = id_json,
                .tool_name = owned_tool_name,
                .deadline_ms = std.time.milliTimestamp() + constants.tool_request_timeout_ms,
            });
            callback(ctx, owned_tool_name, correlation_id, tool_args);
        } else {
            try self.sendToolError(id, "Tool handler not available");
        }
    }

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
                const json_str = try json_util.serializeToJson(self.allocator, result);
                defer self.allocator.free(json_str);
                try self.sendToolResultOptional(id, json_str);
            },
            .get_latest_selection => {
                const result = if (self.last_selection) |sel|
                    sel.toResult()
                else
                    mcp_types.SelectionResult{};
                const json_str = try json_util.serializeToJson(self.allocator, result);
                defer self.allocator.free(json_str);
                try self.sendToolResultOptional(id, json_str);
            },
            .execute_code => {
                try self.sendToolError(id, "Jupyter kernel execution not supported in Neovim");
            },
        }
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

                self.sendToolErrorWithId(id_parsed.value, "Tool request timed out") catch |err| {
                    log.warn("Failed to send tool timeout error: {}", .{err});
                };
                pending.deinit(self.allocator);
            }
        }
    }

    fn sendResult(self: *McpServer, id: ?std.json.Value, result: anytype) !void {
        try self.sendMcpResultDirect(id, result);
    }

    fn sendToolResult(self: *McpServer, id: std.json.Value, json_text: []const u8) !void {
        const content = [_]mcp_types.ContentItem{.{ .text = json_text }};
        const tool_result = mcp_types.ToolCallResult{ .content = &content };
        try self.sendMcpResultDirect(id, tool_result);
    }

    fn sendToolResultOptional(self: *McpServer, id: ?std.json.Value, json_text: []const u8) !void {
        const content = [_]mcp_types.ContentItem{.{ .text = json_text }};
        const tool_result = mcp_types.ToolCallResult{ .content = &content };
        try self.sendMcpResultDirect(id, tool_result);
    }

    fn sendToolError(self: *McpServer, id: ?std.json.Value, message: []const u8) !void {
        try self.sendToolErrorImpl(id, message);
    }

    fn sendToolErrorWithId(self: *McpServer, id: std.json.Value, message: []const u8) !void {
        try self.sendToolErrorImpl(id, message);
    }

    fn sendToolErrorImpl(self: *McpServer, id: ?std.json.Value, message: []const u8) !void {
        const content = [_]mcp_types.ContentItem{.{ .text = message }};
        const error_result = ToolErrorResult{ .content = &content, .isError = true };
        try self.sendMcpResultDirect(id, error_result);
    }

    const ToolErrorResult = struct {
        content: []const mcp_types.ContentItem,
        isError: bool,
    };

    fn sendMcpError(self: *McpServer, id: ?std.json.Value, code: i32, message: []const u8) !void {
        const json = try jsonrpc.serializeError(self.allocator, id, code, message);
        defer self.allocator.free(json);
        try self.sendMcpWebSocketMessage(json);
    }

    /// Send a JSON-RPC response with result, serializing directly without std.json.Value round-trip
    fn sendMcpResultDirect(self: *McpServer, id: anytype, result: anytype) !void {
        const json = try jsonrpc.serializeResponseAny(self.allocator, id, result, .{ .emit_null_optional_fields = false });
        defer self.allocator.free(json);
        try self.sendMcpWebSocketMessage(json);
    }

    fn sendMcpWebSocketMessage(self: *McpServer, message: []const u8) !void {
        const frame = try websocket.encodeFrame(self.allocator, .text, message);
        defer self.allocator.free(frame);

        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        const client = self.mcp_client_socket orelse return error.NotConnected;
        _ = try posix.write(client, frame);
    }

    /// Send a JSON-RPC notification to the nvim client
    pub fn sendNvimNotification(self: *McpServer, method: []const u8, params: anytype) !void {
        const json = try jsonrpc.serializeTypedNotification(
            self.allocator,
            method,
            params,
            .{ .emit_null_optional_fields = false },
        );
        defer self.allocator.free(json);

        const frame = try websocket.encodeFrame(self.allocator, .text, json);
        defer self.allocator.free(frame);

        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        const client = self.nvim_client_socket orelse return error.NotConnected;
        _ = try posix.write(client, frame);
    }

    /// Check if nvim client is connected
    pub fn isNvimConnected(self: *McpServer) bool {
        return self.nvim_client_socket != null;
    }
};

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "queueHandshake returns error at capacity without closing socket" {
    const server = try McpServer.init(testing.allocator, "/tmp");
    defer server.deinit();

    var pending_fds: [max_pending_handshakes]posix.socket_t = undefined;
    for (&pending_fds) |*fd| {
        fd.* = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        try server.queueHandshake(fd.*);
    }

    const extra = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    try testing.expectError(error.TooManyPendingHandshakes, server.queueHandshake(extra));
    _ = try posix.fcntl(extra, posix.F.GETFD, 0);
    posix.close(extra);

    server.closePendingHandshakes();
}

test "McpServer init and deinit" {
    const server = try McpServer.init(testing.allocator, "/tmp");
    defer server.deinit();
    const summary = .{
        .port = server.port,
        .mcp_socket = server.mcp_client_socket,
        .nvim_socket = server.nvim_client_socket,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.mcp_server.test.McpServer init and deinit__struct_<^\d+$>
        \\  .port: u16 = <^\d+$>
        \\  .mcp_socket: ?i32
        \\    null
        \\  .nvim_socket: ?i32
        \\    null
    ).expectEqual(summary);
}

test "McpServer port binding" {
    const server1 = try McpServer.init(testing.allocator, "/tmp");
    defer server1.deinit();

    const server2 = try McpServer.init(testing.allocator, "/tmp");
    defer server2.deinit();

    const summary = .{
        .port1 = server1.port,
        .port2 = server2.port,
        .different = server1.port != server2.port,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.mcp_server.test.McpServer port binding__struct_<^\d+$>
        \\  .port1: u16 = <^\d+$>
        \\  .port2: u16 = <^\d+$>
        \\  .different: bool = true
    ).expectEqual(summary);
}

test "setNonBlocking and setBlocking toggle O_NONBLOCK" {
    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(sock);

    const initial_flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    const nonblock_bit: @TypeOf(initial_flags) = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    const initial_nonblock = (initial_flags & nonblock_bit) != 0;

    try McpServer.setNonBlocking(sock);
    const after_nonblock_flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    const after_nonblock = (after_nonblock_flags & nonblock_bit) != 0;

    try McpServer.setBlocking(sock);
    const after_blocking_flags = try posix.fcntl(sock, posix.F.GETFL, 0);
    const after_blocking = (after_blocking_flags & nonblock_bit) != 0;

    const summary = .{
        .initial_nonblock = initial_nonblock,
        .after_nonblock = after_nonblock,
        .after_blocking = after_blocking,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.mcp_server.test.setNonBlocking and setBlocking toggle O_NONBLOCK__struct_<^\d+$>
        \\  .initial_nonblock: bool = false
        \\  .after_nonblock: bool = true
        \\  .after_blocking: bool = false
    ).expectEqual(summary);
}
