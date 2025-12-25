const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("protocol.zig");
const Bridge = @import("../cli/bridge.zig").Bridge;
const settings_loader = @import("../settings/loader.zig");
const Settings = settings_loader.Settings;

const log = std.log.scoped(.agent);

// JSON-RPC method parameter schemas
const NewSessionParams = struct {
    cwd: []const u8 = ".",
};

const PromptParams = struct {
    sessionId: []const u8,
    prompt: ?[]const u8 = null,
};

const CancelParams = struct {
    sessionId: []const u8,
};

const SetModeParams = struct {
    sessionId: []const u8,
    mode: []const u8,
};

const ResumeSessionParams = struct {
    sessionId: []const u8,
    cwd: []const u8 = ".",
};

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
        settings: ?Settings = null,

        pub fn deinit(self: *Session, allocator: Allocator) void {
            if (self.bridge) |*b| b.deinit();
            if (self.settings) |*s| s.deinit();
            allocator.free(self.id);
            allocator.free(self.cwd);
        }

        /// Check if a tool is allowed based on settings
        pub fn isToolAllowed(self: *const Session, tool_name: []const u8) bool {
            if (self.settings) |*s| {
                // Explicit deny takes precedence
                if (s.isDenied(tool_name)) return false;
                // Explicit allow
                if (s.isAllowed(tool_name)) return true;
            }
            // Default: allow (will prompt user via ACP permission request)
            return true;
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
        // Parse client capabilities
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("clientCapabilities")) |caps| {
                    const parsed = std.json.parseFromValue(
                        protocol.ClientCapabilities,
                        self.allocator,
                        caps,
                        .{ .ignore_unknown_fields = true },
                    ) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        self.client_capabilities = p.value;
                        log.info("Client capabilities: fs={?}, terminal={?}", .{
                            if (self.client_capabilities.?.fs) |fs| fs.readTextFile else null,
                            self.client_capabilities.?.terminal,
                        });
                    }
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
        const hex = std.fmt.bytesToHex(uuid_bytes, .lower);
        const session_id = try self.allocator.dupe(u8, &hex);

        // Parse params using typed struct
        const parsed = try std.json.parseFromValue(NewSessionParams, self.allocator, request.params orelse .null, .{});
        defer parsed.deinit();
        const cwd = parsed.value.cwd;

        // Load settings from project directory
        // Note: FileNotFound is handled internally by loader (returns empty settings)
        // Other errors (parse failure, permission denied) mean settings file exists but is broken
        const settings = settings_loader.loadSettings(self.allocator, cwd) catch |err| blk: {
            log.err("Settings parse failed in {s}: {} - tool permissions disabled (all tools allowed)", .{ cwd, err });
            break :blk null;
        };

        // Create session
        const session = try self.allocator.create(Session);
        session.* = .{
            .id = session_id,
            .cwd = try self.allocator.dupe(u8, cwd),
            .settings = settings,
        };
        try self.sessions.put(session_id, session);

        log.info("Created session {s} in {s}", .{ session_id, cwd });

        // Build response
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try result.object.put("sessionId", .{ .string = session_id });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handlePrompt(self: *Agent, request: jsonrpc.Request) !void {
        // Parse params using typed struct
        const parsed = std.json.parseFromValue(PromptParams, self.allocator, request.params orelse .null, .{}) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing or invalid sessionId",
            ));
            return;
        };
        defer parsed.deinit();
        const session_id = parsed.value.sessionId;
        const prompt_text = parsed.value.prompt;

        const session = self.sessions.get(session_id) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session not found",
            ));
            return;
        };

        session.cancelled = false;
        log.info("Prompt received for session {s}", .{session_id});

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
        var stop_reason_owned: ?[]u8 = null;
        defer if (stop_reason_owned) |s| self.allocator.free(s);
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
                        try self.sendSessionUpdate(session_id, .{
                            .kind = .text,
                            .content = content,
                        });
                    }

                    // Check for tool use - apply permission hooks
                    if (msg.getToolName()) |tool_name| {
                        if (!session.isToolAllowed(tool_name)) {
                            log.warn("Tool {s} denied by settings", .{tool_name});
                            try self.sendSessionUpdate(session_id, .{
                                .kind = .text,
                                .content = "Tool execution blocked by settings.",
                            });
                            // Note: CLI will continue, we're just notifying user
                        } else {
                            try self.sendSessionUpdate(session_id, .{
                                .kind = .tool_call,
                                .title = tool_name,
                            });
                        }
                    }
                },
                .result => {
                    if (msg.getStopReason()) |reason| {
                        stop_reason_owned = self.allocator.dupe(u8, reason) catch null;
                        if (stop_reason_owned) |s| stop_reason = s;
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
                                    log.warn("Auth required for session {s}", .{session_id});
                                    // Send friendly message to user instead of error
                                    try self.sendSessionUpdate(session_id, .{
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
        const parsed = std.json.parseFromValue(CancelParams, self.allocator, request.params orelse .null, .{}) catch return;
        defer parsed.deinit();

        if (self.sessions.get(parsed.value.sessionId)) |session| {
            session.cancelled = true;
            if (session.bridge) |*bridge| {
                bridge.stop();
            }
            log.info("Cancelled session {s}", .{parsed.value.sessionId});
        }
        // Cancel is a notification, no response needed
    }

    fn handleSetMode(self: *Agent, request: jsonrpc.Request) !void {
        const parsed = std.json.parseFromValue(SetModeParams, self.allocator, request.params orelse .null, .{}) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId or mode",
            ));
            return;
        };
        defer parsed.deinit();
        const params = parsed.value;

        const session = self.sessions.get(params.sessionId) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session not found",
            ));
            return;
        };

        session.permission_mode = std.meta.stringToEnum(protocol.PermissionMode, params.mode) orelse .default;
        log.info("Set mode for session {s} to {s}", .{ params.sessionId, params.mode });

        const result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleResumeSession(self: *Agent, request: jsonrpc.Request) !void {
        const parsed = std.json.parseFromValue(ResumeSessionParams, self.allocator, request.params orelse .null, .{}) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId",
            ));
            return;
        };
        defer parsed.deinit();
        const params = parsed.value;

        // Check if session already exists
        if (self.sessions.get(params.sessionId)) |_| {
            var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
            try result.object.put("sessionId", .{ .string = params.sessionId });
            try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
            return;
        }

        // Create new session
        const session = try self.allocator.create(Session);
        const sid_copy = try self.allocator.dupe(u8, params.sessionId);
        session.* = .{
            .id = sid_copy,
            .cwd = try self.allocator.dupe(u8, params.cwd),
        };
        try self.sessions.put(sid_copy, session);

        log.info("Resumed session {s}", .{sid_copy});

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        try result.object.put("sessionId", .{ .string = sid_copy });
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
