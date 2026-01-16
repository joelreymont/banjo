const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const lockfile = @import("lockfile.zig");
const websocket = @import("websocket.zig");
const protocol = @import("protocol.zig");
const constants = @import("../core/constants.zig");
const jsonrpc = @import("../jsonrpc.zig");
const ws_transport = @import("../acp/ws_transport.zig");
const Agent = @import("../acp/agent.zig").Agent;

const log = std.log.scoped(.mcp_server);
const debug_log = @import("../util/debug_log.zig");
const byte_queue = @import("../util/byte_queue.zig");

const max_pending_handshakes: usize = 8;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    debug_log.write("WS", fmt, args);
}

pub const McpServer = struct {
    allocator: Allocator,
    tcp_socket: posix.socket_t,
    nvim_client_socket: ?posix.socket_t = null,
    lock_file: ?lockfile.LockFile = null,
    port: u16,
    cwd: []const u8,

    // Read buffer for WebSocket frames
    nvim_read_buffer: byte_queue.ByteQueue = .{},
    pending_handshakes: std.AutoHashMap(posix.socket_t, PendingHandshake),

    // Mutex for socket operations (protects nvim_client_socket)
    socket_mutex: std.Thread.Mutex = .{},

    // Mutex for poll operations (ensures single-threaded polling)
    poll_mutex: std.Thread.Mutex = .{},

    // Callback for nvim messages (prompt, cancel, etc.)
    nvim_message_callback: ?*const fn (ctx: *anyopaque, method: []const u8, params: ?std.json.Value) void = null,
    nvim_callback_ctx: ?*anyopaque = null,

    // Callback for nvim connection (send initial state)
    nvim_connect_callback: ?*const fn (ctx: *anyopaque) void = null,

    // ACP client connection
    acp_client: ?*AcpConnection = null,

    const AcpConnection = struct {
        socket: posix.socket_t,
        agent: Agent,
        ws_writer: ws_transport.WsWriter,
        ws_reader: ws_transport.WsReader,
        jsonrpc_reader: jsonrpc.Reader,

        fn init(allocator: Allocator, socket: posix.socket_t, mutex: *std.Thread.Mutex) !*AcpConnection {
            const conn = try allocator.create(AcpConnection);
            conn.* = .{
                .socket = socket,
                .ws_writer = ws_transport.WsWriter.init(allocator, socket, mutex),
                .ws_reader = ws_transport.WsReader.init(allocator, socket),
                .jsonrpc_reader = undefined,
                .agent = undefined,
            };
            conn.jsonrpc_reader = jsonrpc.Reader.init(allocator, conn.ws_reader.reader());
            conn.agent = Agent.init(allocator, conn.ws_writer.writer(), &conn.jsonrpc_reader);
            return conn;
        }

        fn deinit(self: *AcpConnection, allocator: Allocator) void {
            self.agent.deinit();
            self.ws_writer.deinit();
            self.ws_reader.deinit();
            self.jsonrpc_reader.deinit();
            posix.close(self.socket);
            allocator.destroy(self);
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

        const self = try allocator.create(McpServer);
        self.* = McpServer{
            .allocator = allocator,
            .tcp_socket = sock,
            .port = port,
            .cwd = cwd,
            .pending_handshakes = std.AutoHashMap(posix.socket_t, PendingHandshake).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *McpServer) void {
        self.stop();
        self.closePendingHandshakes();
        self.pending_handshakes.deinit();
        self.nvim_read_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn start(self: *McpServer) !void {
        // Create lock file
        self.lock_file = try lockfile.create(
            self.allocator,
            self.port,
            self.cwd,
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

        var fds: [max_pending_handshakes + 4]posix.pollfd = undefined;
        var nfds: usize = 0;

        const can_accept = self.pending_handshakes.count() < max_pending_handshakes;
        if (can_accept) {
            fds[nfds] = .{ .fd = self.tcp_socket, .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        // Poll nvim client socket if connected
        if (self.nvim_client_socket) |sock| {
            fds[nfds] = .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 };
            nfds += 1;
        }

        // Poll ACP client socket if connected
        if (self.acp_client) |conn| {
            fds[nfds] = .{ .fd = conn.socket, .events = posix.POLL.IN, .revents = 0 };
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
            // Timeout - check handshakes
            self.expirePendingHandshakes(std.time.milliTimestamp());
            return true;
        }
        debugLog("poll: ready={d}, nfds={d}, nvim_connected={}, acp_connected={}", .{ ready, nfds, self.nvim_client_socket != null, self.acp_client != null });

        // Handle events
        for (fds[0..nfds]) |fd| {
            if (fd.revents & posix.POLL.IN != 0) {
                if (fd.fd == self.tcp_socket) {
                    self.acceptConnection() catch |err| {
                        log.warn("Accept failed: {}", .{err});
                    };
                } else if (self.nvim_client_socket != null and fd.fd == self.nvim_client_socket.?) {
                    debugLog("poll: nvim socket has data", .{});
                    self.handleNvimClientMessage() catch |err| {
                        log.warn("Nvim client message failed: {}", .{err});
                        self.closeNvimClient();
                    };
                } else if (self.acp_client != null and fd.fd == self.acp_client.?.socket) {
                    debugLog("poll: acp socket has data", .{});
                    self.handleAcpClientMessage() catch |err| {
                        log.warn("ACP client message failed: {}", .{err});
                        self.closeAcpClient();
                    };
                } else if (self.pending_handshakes.getPtr(fd.fd)) |pending| {
                    self.handlePendingHandshake(fd.fd, pending);
                }
            }
            // Guard: socket may have been closed in error handler above
            if (fd.revents & posix.POLL.HUP != 0 or fd.revents & posix.POLL.ERR != 0) {
                if (self.nvim_client_socket != null and fd.fd == self.nvim_client_socket.?) {
                    log.info("Nvim client disconnected", .{});
                    self.closeNvimClient();
                }
                if (self.acp_client != null and fd.fd == self.acp_client.?.socket) {
                    log.info("ACP client disconnected", .{});
                    self.closeAcpClient();
                }
                if (self.pending_handshakes.contains(fd.fd)) {
                    log.info("Handshake client disconnected", .{});
                    self.closePendingHandshake(fd.fd);
                }
            }
        }

        self.expirePendingHandshakes(std.time.milliTimestamp());
        return true;
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

    fn closeAcpClient(self: *McpServer) void {
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();
        if (self.acp_client) |conn| {
            conn.deinit(self.allocator);
            self.acp_client = null;
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
        switch (client_kind) {
            .nvim => try self.finishNvimHandshake(client, remainder),
            .acp => try self.finishAcpHandshake(client, remainder),
        }
    }

    fn finishNvimHandshake(self: *McpServer, client: posix.socket_t, remainder: []const u8) !void {
        var cb: ?*const fn (ctx: *anyopaque) void = null;
        var cb_ctx: ?*anyopaque = null;

        self.socket_mutex.lock();
        errdefer self.socket_mutex.unlock();

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
        if (self.nvim_connect_callback) |cb_fn| {
            if (self.nvim_callback_ctx) |ctx| {
                cb = cb_fn;
                cb_ctx = ctx;
            }
        }

        self.socket_mutex.unlock();

        if (cb) |cb_fn| {
            if (cb_ctx) |ctx| {
                cb_fn(ctx);
            }
        }
    }

    fn finishAcpHandshake(self: *McpServer, client: posix.socket_t, remainder: []const u8) !void {
        self.socket_mutex.lock();
        defer self.socket_mutex.unlock();

        // Close existing ACP connection if any
        if (self.acp_client) |old| {
            log.info("Closing existing ACP client connection", .{});
            old.deinit(self.allocator);
        }

        // Create new ACP connection
        const conn = try AcpConnection.init(self.allocator, client, &self.socket_mutex);
        errdefer conn.deinit(self.allocator);

        // Add any remainder data to the reader buffer
        if (remainder.len > 0) {
            try conn.ws_reader.frame_buffer.append(self.allocator, remainder);
        }

        self.acp_client = conn;
        log.info("ACP client connected", .{});
        debugLog("acp_client_socket set to fd={d}", .{client});
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

        const client_kind = websocket.completeHandshake(fd, parsed.result) catch |err| {
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
            const buf = self.nvim_read_buffer.sliceMut();
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
        const parsed = std.json.parseFromSlice(protocol.JsonRpcRequest, self.allocator, payload, .{
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

    fn handleAcpClientMessage(self: *McpServer) !void {
        debugLog("handleAcpClientMessage: entry", .{});
        const conn = self.acp_client orelse return;

        // Read available data into frame buffer
        var temp_buf: [4096]u8 = undefined;
        const n = posix.read(conn.socket, &temp_buf) catch |err| switch (err) {
            error.WouldBlock => {
                debugLog("handleAcpClientMessage: WouldBlock", .{});
                return;
            },
            else => return err,
        };
        if (n == 0) return error.ConnectionClosed;
        debugLog("handleAcpClientMessage: read {d} bytes", .{n});

        try conn.ws_reader.frame_buffer.append(self.allocator, temp_buf[0..n]);

        // Try to parse complete frames
        while (conn.ws_reader.frame_buffer.len() >= 2) {
            const buf = conn.ws_reader.frame_buffer.sliceMut();
            const result = websocket.parseFrame(buf) catch |err| switch (err) {
                error.NeedMoreData => break,
                error.ReservedOpcode => {
                    log.warn("Received ACP frame with reserved opcode, closing", .{});
                    self.closeAcpClient();
                    return;
                },
                error.UnmaskedFrame => {
                    log.warn("Received unmasked ACP frame, closing", .{});
                    self.closeAcpClient();
                    return;
                },
                else => return err,
            };

            switch (result.frame.opcode) {
                .text => {
                    try self.handleAcpJsonRpcMessage(result.frame.payload);
                },
                .ping => {
                    const pong = try websocket.encodeFrame(self.allocator, .pong, result.frame.payload);
                    defer self.allocator.free(pong);
                    self.socket_mutex.lock();
                    defer self.socket_mutex.unlock();
                    if (self.acp_client) |c| {
                        _ = try posix.write(c.socket, pong);
                    }
                },
                .close => {
                    log.info("ACP client sent close frame", .{});
                    self.closeAcpClient();
                    return;
                },
                else => {},
            }

            conn.ws_reader.frame_buffer.consume(result.consumed);
        }
    }

    fn handleAcpJsonRpcMessage(self: *McpServer, payload: []const u8) !void {
        debugLog("handleAcpJsonRpcMessage: payload={d} bytes", .{payload.len});
        const conn = self.acp_client orelse return;

        var parsed = try jsonrpc.parseMessage(self.allocator, payload);
        defer parsed.deinit();

        try conn.agent.handleMessage(parsed.message);
    }
};

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

const ConnCtx = struct {
    server: *McpServer,
    can_lock: bool = false,
};

fn connCb(ctx: *anyopaque) void {
    const conn: *ConnCtx = @ptrCast(@alignCast(ctx));
    if (conn.server.socket_mutex.tryLock()) {
        conn.can_lock = true;
        conn.server.socket_mutex.unlock();
    }
}

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

test "finishHandshake releases socket lock before nvim callback" {
    const server = try McpServer.init(testing.allocator, "/tmp");
    defer server.deinit();

    var ctx = ConnCtx{ .server = server };
    server.nvim_connect_callback = connCb;
    server.nvim_callback_ctx = &ctx;

    const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var owns_sock = true;
    defer if (owns_sock) posix.close(sock);

    try server.finishHandshake(.nvim, sock, &.{});
    owns_sock = false;

    const can_lock = ctx.can_lock;
    server.socket_mutex.lock();
    const held = server.nvim_client_socket.?;
    server.nvim_client_socket = null;
    server.socket_mutex.unlock();
    posix.close(held);

    try testing.expect(can_lock);
}

test "McpServer init and deinit" {
    const server = try McpServer.init(testing.allocator, "/tmp");
    defer server.deinit();
    const summary = .{
        .port = server.port,
        .nvim_socket = server.nvim_client_socket,
    };
    try (ohsnap{}).snap(@src(),
        \\ws.mcp_server.test.McpServer init and deinit__struct_<^\d+$>
        \\  .port: u16 = <^\d+$>
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
        \\ws.mcp_server.test.McpServer port binding__struct_<^\d+$>
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
        \\ws.mcp_server.test.setNonBlocking and setBlocking toggle O_NONBLOCK__struct_<^\d+$>
        \\  .initial_nonblock: bool = false
        \\  .after_nonblock: bool = true
        \\  .after_blocking: bool = false
    ).expectEqual(summary);
}
