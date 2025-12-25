const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("protocol.zig");
const Bridge = @import("../cli/bridge.zig").Bridge;
const settings_loader = @import("../settings/loader.zig");
const Settings = settings_loader.Settings;

const log = std.log.scoped(.agent);

// JSON-RPC method parameter schemas
// See docs/acp-protocol.md for full specification

const NewSessionParams = struct {
    cwd: []const u8 = ".",
    mcpServers: ?std.json.Value = null, // Array of MCP server configs (we store raw for now)
};

const PromptParams = struct {
    sessionId: []const u8,
    prompt: ?std.json.Value = null, // Array of content blocks
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

/// Extract text content from ACP prompt content blocks array
fn extractTextFromPrompt(prompt: ?std.json.Value) ?[]const u8 {
    const blocks = prompt orelse return null;
    if (blocks != .array) return null;
    for (blocks.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;
        if (!std.mem.eql(u8, block_type.string, "text")) continue;
        const text = block.object.get("text") orelse continue;
        if (text == .string) return text.string;
    }
    return null;
}

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
        } else if (std.mem.eql(u8, request.method, "authenticate")) {
            try self.handleAuthenticate(request);
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
        // Validate protocol version
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("protocolVersion")) |ver| {
                    if (ver == .integer) {
                        if (ver.integer != protocol.ProtocolVersion) {
                            try self.writer.writeResponse(jsonrpc.Response.err(
                                request.id,
                                jsonrpc.Error.InvalidParams,
                                "Unsupported protocol version",
                            ));
                            return;
                        }
                    }
                }
            }
        }

        // Parse client capabilities
        if (request.params) |params| {
            if (params == .object) {
                if (params.object.get("clientCapabilities")) |caps| {
                    if (std.json.parseFromValue(
                        protocol.ClientCapabilities,
                        self.allocator,
                        caps,
                        .{ .ignore_unknown_fields = true },
                    )) |parsed| {
                        defer parsed.deinit();
                        self.client_capabilities = parsed.value;
                        log.info("Client capabilities: fs={?}, terminal={?}", .{
                            if (self.client_capabilities.?.fs) |fs| fs.readTextFile else null,
                            self.client_capabilities.?.terminal,
                        });
                    } else |err| {
                        log.warn("Failed to parse client capabilities: {}", .{err});
                    }
                }
            }
        }

        // Build response struct and serialize directly
        const response = protocol.InitializeResponse{
            .agentInfo = .{
                .name = "Claude Code (Banjo)",
                .title = "Claude Code (Banjo)",
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
                    .@"resume" = .{},
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

        try self.writer.writeTypedResponse(request.id, response);
    }

    fn handleAuthenticate(self: *Agent, request: jsonrpc.Request) !void {
        // For now, we don't require authentication - Claude CLI handles it
        // Just return success with empty result
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleNewSession(self: *Agent, request: jsonrpc.Request) !void {
        // Generate session ID
        var uuid_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&uuid_bytes);
        const hex = std.fmt.bytesToHex(uuid_bytes, .lower);
        const session_id = try self.allocator.dupe(u8, &hex);

        // Parse params using typed struct
        const parsed = try std.json.parseFromValue(NewSessionParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        });
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
        defer result.object.deinit();
        try result.object.put("sessionId", .{ .string = session_id });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handlePrompt(self: *Agent, request: jsonrpc.Request) !void {
        // Parse params using typed struct
        const parsed = std.json.parseFromValue(PromptParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing or invalid sessionId",
            ));
            return;
        };
        defer parsed.deinit();
        const session_id = parsed.value.sessionId;

        // Extract text from content blocks array
        const prompt_text = extractTextFromPrompt(parsed.value.prompt);

        const session = self.sessions.get(session_id) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session not found",
            ));
            return;
        };

        session.cancelled = false;
        log.info("Prompt received for session {s}: {s}", .{ session_id, prompt_text orelse "(empty)" });

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

        while (true) {
            // Check cancellation at loop start
            if (session.cancelled) {
                stop_reason = "cancelled";
                break;
            }
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
                                .kind = .tool_use,
                                .title = tool_name,
                            });
                        }
                    }
                },
                .result => {
                    if (msg.getStopReason()) |reason| {
                        stop_reason_owned = try self.allocator.dupe(u8, reason);
                        stop_reason = stop_reason_owned.?;
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
        defer result.object.deinit();
        try result.object.put("stopReason", .{ .string = stop_reason });

        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleCancel(self: *Agent, request: jsonrpc.Request) !void {
        const parsed = std.json.parseFromValue(CancelParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch return;
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
        const parsed = std.json.parseFromValue(SetModeParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch {
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

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    fn handleResumeSession(self: *Agent, request: jsonrpc.Request) !void {
        const parsed = std.json.parseFromValue(ResumeSessionParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch {
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
            defer result.object.deinit();
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
        defer result.object.deinit();
        try result.object.put("sessionId", .{ .string = sid_copy });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    /// Send a session update notification
    pub fn sendSessionUpdate(self: *Agent, session_id: []const u8, update: protocol.SessionUpdate.Update) !void {
        // Use typed notification to avoid manual json.Value construction
        // (prevents use-after-free from nested ObjectMap aliasing)
        const session_update = protocol.SessionUpdate{
            .sessionId = session_id,
            .update = update,
        };
        try self.writer.writeTypedNotification("session/update", session_update);
    }
};

// Tests
const testing = std.testing;

/// Test helper for capturing JSON-RPC output.
/// Heap-allocates the GenericWriter to ensure AnyWriter context pointer remains valid.
const TestWriter = struct {
    output: *std.ArrayList(u8),
    list_writer: *std.ArrayList(u8).Writer,
    writer: jsonrpc.Writer,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !TestWriter {
        const output = try allocator.create(std.ArrayList(u8));
        errdefer allocator.destroy(output);
        output.* = .empty;

        const list_writer = try allocator.create(std.ArrayList(u8).Writer);
        errdefer allocator.destroy(list_writer);
        list_writer.* = output.writer(allocator);

        return .{
            .output = output,
            .list_writer = list_writer,
            .writer = jsonrpc.Writer.init(allocator, list_writer.any()),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TestWriter) void {
        self.output.deinit(self.allocator);
        self.allocator.destroy(self.output);
        self.allocator.destroy(self.list_writer);
    }

    pub fn getOutput(self: *TestWriter) []const u8 {
        return self.output.items;
    }
};

test "Agent init/deinit" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();
}

test "Agent handleRequest - initialize" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "initialize",
        .id = .{ .number = 1 },
    };

    try agent.handleRequest(request);

    // Check that a response was written
    try testing.expect(tw.getOutput().len > 0);

    // Parse the response
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Verify it's a success response
    try testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    try testing.expect(parsed.value.object.get("result") != null);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
}

test "Agent handleRequest - newSession" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 2 },
        .params = .{ .object = std.json.ObjectMap.init(testing.allocator) },
    };

    try agent.handleRequest(request);

    // Check response
    try testing.expect(tw.getOutput().len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should have a sessionId in result
    const result = parsed.value.object.get("result").?.object;
    try testing.expect(result.get("sessionId") != null);
}

test "Agent handleRequest - methodNotFound" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "nonexistent/method",
        .id = .{ .number = 99 },
    };

    try agent.handleRequest(request);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be an error response
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.MethodNotFound), err.get("code").?.integer);
}

test "Agent handleRequest - setMode" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // First create a session
    var new_session_params = std.json.ObjectMap.init(testing.allocator);
    defer new_session_params.deinit();

    const create_request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = new_session_params },
    };
    try agent.handleRequest(create_request);

    // Parse the session ID from response
    const create_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer create_parsed.deinit();
    const session_id = create_parsed.value.object.get("result").?.object.get("sessionId").?.string;

    // Clear output for next request
    tw.output.clearRetainingCapacity();

    // Set mode to plan
    var set_mode_params = std.json.ObjectMap.init(testing.allocator);
    defer set_mode_params.deinit();
    try set_mode_params.put("sessionId", .{ .string = session_id });
    try set_mode_params.put("mode", .{ .string = "plan" });

    const set_mode_request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 2 },
        .params = .{ .object = set_mode_params },
    };
    try agent.handleRequest(set_mode_request);

    // Should succeed with empty result
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("result") != null);
    try testing.expectEqual(@as(i64, 2), parsed.value.object.get("id").?.integer);
}

test "Agent handleRequest - setMode session not found" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "nonexistent" });
    try params.put("mode", .{ .string = "plan" });

    const request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };
    try agent.handleRequest(request);

    // Should return error - session not found
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.InvalidParams), err.get("code").?.integer);
}

test "Agent handleRequest - resumeSession" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "test-session-123" });
    try params.put("cwd", .{ .string = "." });

    const request = jsonrpc.Request{
        .method = "unstable_resumeSession",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };
    try agent.handleRequest(request);

    // Should succeed and return sessionId
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try testing.expectEqualStrings("test-session-123", result.get("sessionId").?.string);
}

test "Agent handleRequest - resumeSession existing" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // First create a session
    var new_session_params = std.json.ObjectMap.init(testing.allocator);
    defer new_session_params.deinit();

    const create_request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = new_session_params },
    };
    try agent.handleRequest(create_request);

    // Get the session ID
    const create_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer create_parsed.deinit();
    const session_id = create_parsed.value.object.get("result").?.object.get("sessionId").?.string;

    // Clear output
    tw.output.clearRetainingCapacity();

    // Resume the same session
    var resume_params = std.json.ObjectMap.init(testing.allocator);
    defer resume_params.deinit();
    try resume_params.put("sessionId", .{ .string = session_id });

    const resume_request = jsonrpc.Request{
        .method = "unstable_resumeSession",
        .id = .{ .number = 2 },
        .params = .{ .object = resume_params },
    };
    try agent.handleRequest(resume_request);

    // Should return the same sessionId (session already exists)
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try testing.expectEqualStrings(session_id, result.get("sessionId").?.string);
}

// =============================================================================
// Property Tests for Prompt Extraction
// =============================================================================

const quickcheck = @import("../util/quickcheck.zig");

/// Build a prompt JSON from test parameters
fn buildTestPrompt(
    allocator: std.mem.Allocator,
    num_non_text: u8,
    has_text: bool,
    text_idx: u8,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    const actual_text_pos = if (has_text) text_idx % (num_non_text + 1) else num_non_text + 1;
    var pos: u8 = 0;

    // Insert non-text blocks and optionally a text block
    for (0..num_non_text + 1) |_| {
        if (has_text and pos == actual_text_pos) {
            var text_block = std.json.ObjectMap.init(allocator);
            errdefer text_block.deinit();
            try text_block.put("type", .{ .string = "text" });
            try text_block.put("text", .{ .string = "expected_text" });
            try array.append(.{ .object = text_block });
        }
        if (pos < num_non_text) {
            var img_block = std.json.ObjectMap.init(allocator);
            errdefer img_block.deinit();
            try img_block.put("type", .{ .string = "image" });
            try array.append(.{ .object = img_block });
        }
        pos += 1;
    }

    return .{ .array = array };
}

fn freeTestPrompt(allocator: std.mem.Allocator, prompt: *std.json.Value) void {
    _ = allocator;
    for (prompt.array.items) |*item| {
        item.object.deinit();
    }
    prompt.array.deinit();
}

test "property: extractTextFromPrompt finds text regardless of position" {
    try quickcheck.check(struct {
        fn prop(args: struct { num_non_text: u4, text_pos: u4 }) bool {
            var prompt = buildTestPrompt(
                testing.allocator,
                args.num_non_text,
                true,
                args.text_pos,
            ) catch return false;
            defer freeTestPrompt(testing.allocator, &prompt);

            const result = extractTextFromPrompt(prompt);
            return result != null and std.mem.eql(u8, result.?, "expected_text");
        }
    }.prop, .{});
}

test "property: extractTextFromPrompt returns null when no text block" {
    try quickcheck.check(struct {
        fn prop(args: struct { num_non_text: u4 }) bool {
            var prompt = buildTestPrompt(
                testing.allocator,
                args.num_non_text,
                false,
                0,
            ) catch return false;
            defer freeTestPrompt(testing.allocator, &prompt);

            return extractTextFromPrompt(prompt) == null;
        }
    }.prop, .{});
}

test "property: extractTextFromPrompt null/non-array always returns null" {
    // Null always returns null
    if (extractTextFromPrompt(null) != null) return error.TestFailed;

    // Non-array types always return null
    try quickcheck.check(struct {
        fn prop(args: struct { int_val: i32, bool_val: bool }) bool {
            if (extractTextFromPrompt(.{ .integer = args.int_val }) != null) return false;
            if (extractTextFromPrompt(.{ .bool = args.bool_val }) != null) return false;
            if (extractTextFromPrompt(.{ .float = 3.14 }) != null) return false;
            return true;
        }
    }.prop, .{});
}

test "Agent handleRequest - cancel" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // First create a session
    var new_session_params = std.json.ObjectMap.init(testing.allocator);
    defer new_session_params.deinit();

    const create_request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = new_session_params },
    };
    try agent.handleRequest(create_request);

    // Get the session ID
    const create_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer create_parsed.deinit();
    const session_id = create_parsed.value.object.get("result").?.object.get("sessionId").?.string;

    // Clear output
    tw.output.clearRetainingCapacity();

    // Cancel the session (notification - no id)
    var cancel_params = std.json.ObjectMap.init(testing.allocator);
    defer cancel_params.deinit();
    try cancel_params.put("sessionId", .{ .string = session_id });

    const cancel_request = jsonrpc.Request{
        .method = "session/cancel",
        .id = null, // notification
        .params = .{ .object = cancel_params },
    };
    try agent.handleRequest(cancel_request);

    // Cancel is a notification, no response expected
    try testing.expectEqual(@as(usize, 0), tw.getOutput().len);

    // Verify session was marked as cancelled
    const session = agent.sessions.get(session_id).?;
    try testing.expect(session.cancelled);
}
