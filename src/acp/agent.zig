const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("protocol.zig");
const Bridge = @import("../cli/bridge.zig").Bridge;

const log = std.log.scoped(.agent);

pub const Agent = struct {
    allocator: Allocator,
    writer: jsonrpc.Writer,
    sessions: std.StringHashMap(*Session),
    client_capabilities: ?protocol.ClientCapabilities = null,

    const Session = struct {
        id: []const u8,
        cwd: []const u8,
        cancelled: bool = false,
        permission_mode: protocol.PermissionMode = .default,
        bridge: ?Bridge = null,

        pub fn deinit(self: *Session, allocator: Allocator) void {
            if (self.bridge) |*b| b.deinit();
            allocator.free(self.id);
            allocator.free(self.cwd);
        }
    };

    pub fn init(allocator: Allocator, writer: std.io.AnyWriter) Agent {
        return .{
            .allocator = allocator,
            .writer = jsonrpc.Writer.init(allocator, writer),
            .sessions = std.StringHashMap(*Session).init(allocator),
        };
    }

    pub fn deinit(self: *Agent) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
    }

    /// Handle an incoming JSON-RPC request
    pub fn handleRequest(self: *Agent, request: jsonrpc.Request) !void {
        log.debug("Handling request: {s}", .{request.method});

        if (std.mem.eql(u8, request.method, "initialize")) {
            try self.handleInitialize(request);
        } else if (std.mem.eql(u8, request.method, "session/new")) {
            try self.handleNewSession(request);
        } else if (std.mem.eql(u8, request.method, "session/prompt")) {
            try self.handlePrompt(request);
        } else if (std.mem.eql(u8, request.method, "session/cancel")) {
            try self.handleCancel(request);
        } else if (std.mem.eql(u8, request.method, "session/set_mode")) {
            try self.handleSetMode(request);
        } else if (std.mem.eql(u8, request.method, "unstable_resumeSession")) {
            try self.handleResumeSession(request);
        } else {
            // Unknown method
            if (!request.isNotification()) {
                try self.writer.writeResponse(jsonrpc.Response.err(
                    request.id,
                    jsonrpc.Error.MethodNotFound,
                    "Method not found",
                ));
            }
        }
    }

    fn handleInitialize(self: *Agent, request: jsonrpc.Request) !void {
        // Parse client capabilities from params
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("clientCapabilities")) |caps| {
                    _ = caps; // TODO: Parse capabilities
                }
            }
        }

        const response = protocol.InitializeResponse{
            .agentInfo = .{
                .name = "banjo",
                .title = "Banjo (Claude Code)",
                .version = "0.1.0",
            },
            .agentCapabilities = .{
                .promptCapabilities = .{
                    .image = true,
                    .embeddedContext = true,
                },
                .mcpCapabilities = .{
                    .http = true,
                    .sse = true,
                },
                .sessionCapabilities = .{
                    .fork = .{},
                    .resume_ = .{},
                },
            },
            .authMethods = &.{
                .{
                    .id = "claude-login",
                    .name = "Log in with Claude Code",
                    .description = "Run `claude /login` in the terminal",
                },
            },
        };

        // Serialize response to JSON value
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try result.object.put("protocolVersion", .{ .integer = protocol.ProtocolVersion });

        // AgentInfo
        var agent_info = std.json.ObjectMap.init(self.allocator);
        try agent_info.put("name", .{ .string = response.agentInfo.name });
        try agent_info.put("title", .{ .string = response.agentInfo.title });
        try agent_info.put("version", .{ .string = response.agentInfo.version });
        try result.object.put("agentInfo", .{ .object = agent_info });

        // AgentCapabilities
        var caps = std.json.ObjectMap.init(self.allocator);
        var prompt_caps = std.json.ObjectMap.init(self.allocator);
        try prompt_caps.put("image", .{ .bool = true });
        try prompt_caps.put("embeddedContext", .{ .bool = true });
        try caps.put("promptCapabilities", .{ .object = prompt_caps });

        var mcp_caps = std.json.ObjectMap.init(self.allocator);
        try mcp_caps.put("http", .{ .bool = true });
        try mcp_caps.put("sse", .{ .bool = true });
        try caps.put("mcpCapabilities", .{ .object = mcp_caps });

        var session_caps = std.json.ObjectMap.init(self.allocator);
        try session_caps.put("fork", .{ .object = std.json.ObjectMap.init(self.allocator) });
        try session_caps.put("resume", .{ .object = std.json.ObjectMap.init(self.allocator) });
        try caps.put("sessionCapabilities", .{ .object = session_caps });

        try result.object.put("agentCapabilities", .{ .object = caps });

        // AuthMethods
        var auth_methods = std.json.Array.init(self.allocator);
        var auth_method = std.json.ObjectMap.init(self.allocator);
        try auth_method.put("id", .{ .string = "claude-login" });
        try auth_method.put("name", .{ .string = "Log in with Claude Code" });
        try auth_method.put("description", .{ .string = "Run `claude /login` in the terminal" });
        try auth_methods.append(.{ .object = auth_method });
        try result.object.put("authMethods", .{ .array = auth_methods });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleNewSession(self: *Agent, request: jsonrpc.Request) !void {
        // Generate session ID
        var uuid_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&uuid_bytes);
        const session_id = try std.fmt.allocPrint(self.allocator, "{x:0>32}", .{std.fmt.fmtSliceHexLower(&uuid_bytes)});

        // Parse cwd from params
        var cwd: []const u8 = ".";
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("cwd")) |cwd_val| {
                    if (cwd_val == .string) {
                        cwd = cwd_val.string;
                    }
                }
            }
        }

        // Create session
        const session = try self.allocator.create(Session);
        session.* = .{
            .id = session_id,
            .cwd = try self.allocator.dupe(u8, cwd),
        };
        try self.sessions.put(session_id, session);

        log.info("Created session {s} in {s}", .{ session_id, cwd });

        // Build response
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try result.object.put("sessionId", .{ .string = session_id });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handlePrompt(self: *Agent, request: jsonrpc.Request) !void {
        // Parse params
        var session_id: ?[]const u8 = null;
        var prompt_text: ?[]const u8 = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("sessionId")) |sid| {
                    if (sid == .string) session_id = sid.string;
                }
                if (params.object.get("prompt")) |p| {
                    if (p == .string) prompt_text = p.string;
                }
            }
        }

        if (session_id == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId",
            ));
            return;
        }

        const session = self.sessions.get(session_id.?) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session not found",
            ));
            return;
        };

        session.cancelled = false;
        log.info("Prompt received for session {s}", .{session_id.?});

        // Start bridge if not running
        if (session.bridge == null) {
            session.bridge = Bridge.init(self.allocator, session.cwd);
            try session.bridge.?.start(.{
                .permission_mode = @tagName(session.permission_mode),
            });
        }

        // Send prompt to CLI
        if (prompt_text) |text| {
            try session.bridge.?.sendPrompt(text);
        }

        // Read and process CLI messages
        var stop_reason: []const u8 = "end_turn";
        const bridge = &session.bridge.?;

        while (!session.cancelled) {
            var msg = bridge.readMessage() catch |err| {
                log.err("Failed to read CLI message: {}", .{err});
                break;
            } orelse break;
            defer msg.deinit();

            switch (msg.type) {
                .assistant => {
                    // Forward text content as session update
                    if (msg.getContent()) |content| {
                        try self.sendSessionUpdate(session_id.?, .{
                            .kind = .text,
                            .content = content,
                        });
                    }

                    // Check for tool use (for future hook support)
                    if (msg.isToolUse()) {
                        try self.sendSessionUpdate(session_id.?, .{
                            .kind = .tool_use,
                            .title = "Tool execution",
                        });
                    }
                },
                .result => {
                    if (msg.getStopReason()) |reason| {
                        stop_reason = reason;
                    }
                    break;
                },
                .system => {
                    // Check for auth required
                    if (msg.subtype) |subtype| {
                        if (std.mem.eql(u8, subtype, "auth_required") or
                            std.mem.eql(u8, subtype, "init"))
                        {
                            // Check content for login prompt
                            if (msg.getContent()) |content| {
                                if (std.mem.indexOf(u8, content, "/login") != null or
                                    std.mem.indexOf(u8, content, "authenticate") != null)
                                {
                                    log.warn("Auth required for session {s}", .{session_id.?});
                                    // Send friendly message to user instead of error
                                    try self.sendSessionUpdate(session_id.?, .{
                                        .kind = .text,
                                        .content = "Authentication required. Please run `claude /login` in your terminal, then try again.",
                                    });
                                    stop_reason = "auth_required";
                                    // Stop the bridge - user needs to login externally
                                    session.bridge.?.stop();
                                    session.bridge = null;
                                    break;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        // Return result
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try result.object.put("stopReason", .{ .string = stop_reason });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleCancel(self: *Agent, request: jsonrpc.Request) !void {
        var session_id: ?[]const u8 = null;
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("sessionId")) |sid| {
                    if (sid == .string) {
                        session_id = sid.string;
                    }
                }
            }
        }

        if (session_id) |sid| {
            if (self.sessions.get(sid)) |session| {
                session.cancelled = true;
                // Stop the CLI bridge
                if (session.bridge) |*bridge| {
                    bridge.stop();
                }
                log.info("Cancelled session {s}", .{sid});
            }
        }
        // Cancel is a notification, no response needed
    }

    fn handleSetMode(self: *Agent, request: jsonrpc.Request) !void {
        // Parse session ID and mode
        var session_id: ?[]const u8 = null;
        var mode_str: ?[]const u8 = null;

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("sessionId")) |sid| {
                    if (sid == .string) session_id = sid.string;
                }
                if (params.object.get("mode")) |m| {
                    if (m == .string) mode_str = m.string;
                }
            }
        }

        if (session_id == null or mode_str == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId or mode",
            ));
            return;
        }

        const session = self.sessions.get(session_id.?) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session not found",
            ));
            return;
        };

        // Parse mode
        session.permission_mode = std.meta.stringToEnum(protocol.PermissionMode, mode_str.?) orelse .default;

        log.info("Set mode for session {s} to {s}", .{ session_id.?, mode_str.? });

        const result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleResumeSession(self: *Agent, request: jsonrpc.Request) !void {
        var session_id: ?[]const u8 = null;
        var cwd: []const u8 = ".";

        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("sessionId")) |sid| {
                    if (sid == .string) session_id = sid.string;
                }
                if (params.object.get("cwd")) |c| {
                    if (c == .string) cwd = c.string;
                }
            }
        }

        if (session_id == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId",
            ));
            return;
        }

        // Create or resume session
        const session = try self.allocator.create(Session);
        const sid_copy = try self.allocator.dupe(u8, session_id.?);
        session.* = .{
            .id = sid_copy,
            .cwd = try self.allocator.dupe(u8, cwd),
        };
        try self.sessions.put(sid_copy, session);

        log.info("Resumed session {s}", .{session_id.?});

        const result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try result.object.put("sessionId", .{ .string = session_id.? });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    /// Send a session update notification
    pub fn sendSessionUpdate(self: *Agent, session_id: []const u8, update: protocol.SessionUpdate.Update) !void {
        var params = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try params.object.put("sessionId", .{ .string = session_id });

        var update_obj = std.json.ObjectMap.init(self.allocator);
        try update_obj.put("kind", .{ .string = @tagName(update.kind) });
        if (update.content) |content| {
            try update_obj.put("content", .{ .string = content });
        }
        if (update.title) |title| {
            try update_obj.put("title", .{ .string = title });
        }
        try params.object.put("update", .{ .object = update_obj });

        try self.writer.writeNotification(.{
            .method = "session/update",
            .params = params,
        });
    }
};
