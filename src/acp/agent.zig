const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("protocol.zig");
const bridge = @import("../cli/bridge.zig");
const Bridge = bridge.Bridge;
const ContentBlockType = bridge.ContentBlockType;
const SystemSubtype = bridge.SystemSubtype;
const CodexBridge = @import("../cli/codex_bridge.zig").CodexBridge;
const settings_loader = @import("../settings/loader.zig");
const Settings = settings_loader.Settings;
const notes_commands = @import("../notes/commands.zig");
const config = @import("config");

const log = std.log.scoped(.agent);

const Engine = enum { claude, codex };

const Route = enum { claude, codex, both };

const RoutingResult = struct {
    route: Route,
    prompt: []const u8,
    consumed: bool,
};

/// Banjo version with git hash
pub const version = "0.3.0 (" ++ config.git_hash ++ ")";

/// Check if auto-resume is enabled (default: true)
fn isAutoResumeEnabled() bool {
    const val = std.posix.getenv("BANJO_AUTO_RESUME") orelse return true;
    return falsey_env_values.get(val) == null;
}

/// Check if content indicates authentication is required
fn isAuthRequiredContent(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "/login") != null or
        std.mem.indexOf(u8, content, "authenticate") != null;
}

/// Map CLI result subtypes to ACP stop reasons
fn mapCliStopReason(cli_reason: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "success", "end_turn" },
        .{ "cancelled", "cancelled" },
        .{ "max_tokens", "max_tokens" },
        .{ "error_max_turns", "max_turn_requests" },
        .{ "error_max_budget_usd", "max_turn_requests" },
    });
    return map.get(cli_reason) orelse "end_turn";
}

fn getDuetDefaultRoute() Route {
    const val = std.posix.getenv("BANJO_DUET_DEFAULT") orelse return .both;
    return route_map.get(val) orelse .both;
}

fn getDuetPrimary() Engine {
    const val = std.posix.getenv("BANJO_DUET_PRIMARY") orelse return .claude;
    return engine_map.get(val) orelse .claude;
}

const falsey_env_values = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "0", {} },
});

const route_map = std.StaticStringMap(Route).initComptime(.{
    .{ "claude", .claude },
    .{ "codex", .codex },
    .{ "both", .both },
});

const engine_map = std.StaticStringMap(Engine).initComptime(.{
    .{ "claude", .claude },
    .{ "codex", .codex },
});

const EngineAvailability = struct {
    claude: bool,
    codex: bool,
};

fn detectEngines() EngineAvailability {
    return .{
        .claude = Bridge.isAvailable(),
        .codex = CodexBridge.isAvailable(),
    };
}

fn engineLabel(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "Claude",
        .codex => "Codex",
    };
}

fn enginePrefix(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "[Claude] ",
        .codex => "[Codex] ",
    };
}

fn mapToolKind(tool_name: []const u8) protocol.SessionUpdate.ToolKind {
    const map = std.StaticStringMap(protocol.SessionUpdate.ToolKind).initComptime(.{
        .{ "Read", .read },
        .{ "Write", .write },
        .{ "Edit", .edit },
        .{ "Bash", .command },
        .{ "Command", .command },
    });
    return map.get(tool_name) orelse .other;
}

fn parseRoutePrefix(text: []const u8, default_route: Route) RoutingResult {
    if (text.len == 0 or text[0] != '/') {
        return .{ .route = default_route, .prompt = text, .consumed = false };
    }

    const routing = matchRoute(text) orelse {
        return .{ .route = default_route, .prompt = text, .consumed = false };
    };

    var idx = routing.prefix_len;
    while (idx < text.len and (text[idx] == ' ' or text[idx] == '\t')) idx += 1;
    return .{ .route = routing.route, .prompt = text[idx..], .consumed = true };
}

const RouteMatch = struct {
    route: Route,
    prefix_len: usize,
};

fn matchRoute(text: []const u8) ?RouteMatch {
    const routes = [_]struct { prefix: []const u8, route: Route }{
        .{ .prefix = "/claude", .route = .claude },
        .{ .prefix = "/codex", .route = .codex },
        .{ .prefix = "/both", .route = .both },
    };

    for (routes) |entry| {
        if (!std.mem.startsWith(u8, text, entry.prefix)) continue;
        if (text.len == entry.prefix.len) {
            return .{ .route = entry.route, .prefix_len = entry.prefix.len };
        }
        const next = text[entry.prefix.len];
        if (next == ' ' or next == '\t' or next == '\n' or next == '\r') {
            return .{ .route = entry.route, .prefix_len = entry.prefix.len };
        }
    }
    return null;
}

// JSON-RPC method parameter schemas
// See docs/acp-protocol.md for full specification

const InitializeParams = struct {
    protocolVersion: ?i64 = null,
    clientCapabilities: ?protocol.ClientCapabilities = null,
};

const NewSessionParams = struct {
    cwd: []const u8 = ".",
    mcpServers: ?std.json.Value = null, // Array of MCP server configs (we store raw for now)
    model: ?[]const u8 = null, // Model alias or full name (e.g. "sonnet", "opus", "claude-sonnet-4-5-20250929")
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
        const type_val = block.object.get("type") orelse continue;
        if (type_val != .string) continue;
        const block_type = ContentBlockType.fromString(type_val.string) orelse continue;
        if (block_type != .text) continue;
        const text = block.object.get("text") orelse continue;
        if (text == .string) return text.string;
    }
    return null;
}

/// Resource block data extracted from prompt
const ResourceData = struct {
    uri: []const u8,
    text: ?[]const u8,
};

/// Extract resource data from prompt content blocks (Zed sends file references as resources)
fn extractResource(prompt: ?std.json.Value) ?ResourceData {
    const blocks = prompt orelse return null;
    if (blocks != .array) return null;
    for (blocks.array.items) |block| {
        if (block != .object) continue;
        const type_val = block.object.get("type") orelse continue;
        if (type_val != .string or !std.mem.eql(u8, type_val.string, "resource")) continue;
        // Resource block: { type: "resource", resource: { uri, text } }
        const resource = block.object.get("resource") orelse continue;
        if (resource != .object) continue;
        const uri = resource.object.get("uri") orelse continue;
        if (uri != .string) continue;
        const text = if (resource.object.get("text")) |t| (if (t == .string) t.string else null) else null;
        return .{ .uri = uri.string, .text = text };
    }
    return null;
}

pub const Agent = struct {
    allocator: Allocator,
    writer: jsonrpc.Writer,
    sessions: std.StringHashMap(*Session),
    client_capabilities: ?protocol.ClientCapabilities = null,
    next_tool_call_id: u64 = 0,

    const Session = struct {
        id: []const u8,
        cwd: []const u8,
        cancelled: bool = false,
        permission_mode: protocol.PermissionMode = .default,
        model: ?[]const u8 = null,
        bridge: ?Bridge = null,
        codex_bridge: ?CodexBridge = null,
        settings: ?Settings = null,
        cli_session_id: ?[]const u8 = null, // Claude Code session ID for --resume
        codex_session_id: ?[]const u8 = null,

        pub fn deinit(self: *Session, allocator: Allocator) void {
            if (self.bridge) |*b| b.deinit();
            if (self.codex_bridge) |*b| b.deinit();
            if (self.settings) |*s| s.deinit();
            allocator.free(self.id);
            allocator.free(self.cwd);
            if (self.model) |m| allocator.free(m);
            if (self.cli_session_id) |sid| allocator.free(sid);
            if (self.codex_session_id) |sid| allocator.free(sid);
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

    const Handler = *const fn (*Agent, jsonrpc.Request) anyerror!void;
    const method_handlers = std.StaticStringMap(Handler).initComptime(.{
        .{ "initialize", handleInitialize },
        .{ "authenticate", handleAuthenticate },
        .{ "session/new", handleNewSession },
        .{ "session/prompt", handlePrompt },
        .{ "session/cancel", handleCancel },
        .{ "session/set_mode", handleSetMode },
        .{ "unstable_resumeSession", handleResumeSession },
    });

    /// Handle an incoming JSON-RPC request
    pub fn handleRequest(self: *Agent, request: jsonrpc.Request) !void {
        log.debug("Handling request: {s}", .{request.method});

        if (method_handlers.get(request.method)) |handler| {
            try handler(self, request);
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
        // Parse params using typed struct
        if (request.params == null) {
            return self.sendInitializeResponse(request);
        }

        const parsed = std.json.parseFromValue(InitializeParams, self.allocator, request.params.?, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse initialize params: {}", .{err});
            // Continue with defaults
            return self.sendInitializeResponse(request);
        };
        defer parsed.deinit();
        const params = parsed.value;

        // Validate protocol version
        if (params.protocolVersion) |ver| {
            if (ver != protocol.ProtocolVersion) {
                try self.writer.writeResponse(jsonrpc.Response.err(
                    request.id,
                    jsonrpc.Error.InvalidParams,
                    "Unsupported protocol version",
                ));
                return;
            }
        }

        // Store client capabilities
        if (params.clientCapabilities) |caps| {
            self.client_capabilities = caps;
            log.info("Client capabilities: fs={?}, terminal={?}", .{
                if (caps.fs) |fs| fs.readTextFile else null,
                caps.terminal,
            });
        }

        try self.sendInitializeResponse(request);
    }

    fn sendInitializeResponse(self: *Agent, request: jsonrpc.Request) !void {
        const response = protocol.InitializeResponse{
            .agentInfo = .{
                .name = "Banjo (Claude Code + Codex)",
                .title = "Banjo (Claude Code + Codex)",
                .version = version,
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
        // For now, we don't require authentication - Claude Code handles it
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
        errdefer self.allocator.free(session_id);

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
        errdefer if (settings) |s| {
            var mutable_settings = s;
            mutable_settings.deinit();
        };

        // Create session
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        const cwd_copy = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(cwd_copy);
        const model_copy = if (parsed.value.model) |m| try self.allocator.dupe(u8, m) else null;
        errdefer if (model_copy) |m| self.allocator.free(m);

        session.* = .{
            .id = session_id,
            .cwd = cwd_copy,
            .model = model_copy,
            .settings = settings,
        };
        try self.sessions.put(session_id, session);

        log.info("Created session {s} in {s} with model {?s}", .{ session_id, cwd, session.model });

        // Auto-setup: create .zed/settings.json if missing (enables banjo LSP)
        const did_setup = self.autoSetupLspIfNeeded(cwd) catch false;

        const availability = detectEngines();

        // Pre-start Claude Code for instant first response (auto-resume last session if enabled)
        if (availability.claude) {
            session.bridge = Bridge.init(self.allocator, session.cwd);
            session.bridge.?.start(.{
                .continue_last = isAutoResumeEnabled(),
                .permission_mode = @tagName(session.permission_mode),
                .model = session.model,
            }) catch |err| {
                log.warn("Failed to pre-start Claude Code: {} - will retry on first prompt", .{err});
                session.bridge = null;
            };
        }

        // Build response - must be sent BEFORE session updates
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try result.object.put("sessionId", .{ .string = session_id });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));

        // Send initial commands (CLI provides full list on first prompt after we send it input)
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .available_commands_update,
            .availableCommands = &initial_commands,
        });

        if (!availability.claude and !availability.codex) {
            try self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{
                    .type = "text",
                    .text = "Banjo could not find Claude Code or Codex. Install one (or set CLAUDE_CODE_EXECUTABLE/CODEX_EXECUTABLE) and restart the agent.",
                },
            });
        }

        // Notify user if auto-setup ran
        if (did_setup) {
            try self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{
                    .type = "text",
                    .text = "✨ Created `.zed/settings.json` to enable banjo-notes LSP.\n\n**Reload workspace** (Cmd+Shift+P → \"workspace: reload\") to activate note features.",
                },
            });
        }
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

        var route = getDuetDefaultRoute();
        var effective_prompt = prompt_text;

        if (prompt_text) |text| {
            const routing = parseRoutePrefix(text, route);
            route = routing.route;
            effective_prompt = routing.prompt;

            if (routing.consumed and effective_prompt.?.len == 0) {
                try self.sendSessionUpdate(session_id, .{
                    .sessionUpdate = .agent_message_chunk,
                    .content = .{ .type = "text", .text = "Usage: /claude <prompt> | /codex <prompt> | /both <prompt>" },
                });
                try self.sendEndTurn(request);
                return;
            }

            const prompt_value = effective_prompt.?;
            if (prompt_value.len > 0 and prompt_value[0] == '/') {
                const resource = extractResource(parsed.value.prompt);
                if (self.dispatchCommand(request, session, session_id, prompt_value, resource)) |transformed| {
                    effective_prompt = transformed;
                } else {
                    return;
                }
            }
        }

        var stop_reason: []const u8 = "end_turn";
        if (effective_prompt) |text| {
            stop_reason = try self.runDuetPrompt(session, session_id, text, route);
        }

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try result.object.put("stopReason", .{ .string = stop_reason });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    const DuetState = enum { start, next_engine, run_engine };

    fn runDuetPrompt(self: *Agent, session: *Session, session_id: []const u8, prompt: []const u8, route: Route) ![]const u8 {
        var stop_reason: []const u8 = "end_turn";
        const primary = getDuetPrimary();

        var engines: [2]Engine = .{ .claude, .codex };
        var count: usize = 0;
        switch (route) {
            .claude => {
                engines[0] = .claude;
                count = 1;
            },
            .codex => {
                engines[0] = .codex;
                count = 1;
            },
            .both => {
                if (primary == .claude) {
                    engines[0] = .claude;
                    engines[1] = .codex;
                } else {
                    engines[0] = .codex;
                    engines[1] = .claude;
                }
                count = 2;
            },
        }

        var idx: usize = 0;
        var current: Engine = .claude;

        state: switch (DuetState.start) {
            .start => continue :state .next_engine,
            .next_engine => {
                if (idx >= count) return stop_reason;
                current = engines[idx];
                idx += 1;
                continue :state .run_engine;
            },
            .run_engine => {
                const reason = switch (current) {
                    .claude => try self.runClaudePrompt(session, session_id, prompt),
                    .codex => try self.runCodexPrompt(session, session_id, prompt),
                };
                stop_reason = mergeStopReason(stop_reason, reason);
                if (session.cancelled) return "cancelled";
                continue :state .next_engine;
            },
        }
    }

    fn mergeStopReason(current: []const u8, next: []const u8) []const u8 {
        if (std.mem.eql(u8, next, "cancelled")) return "cancelled";
        if (std.mem.eql(u8, current, "end_turn")) return next;
        return current;
    }

    fn runClaudePrompt(self: *Agent, session: *Session, session_id: []const u8, prompt: []const u8) ![]const u8 {
        var timer = std.time.Timer.start() catch unreachable;
        const engine = Engine.claude;
        var stream_prefix_pending = true;

        var bridge_started = false;
        if (session.bridge == null) {
            session.bridge = Bridge.init(self.allocator, session.cwd);
        }
        if (session.bridge.?.process == null) {
            session.bridge.?.start(.{
                .resume_session_id = session.cli_session_id,
                .continue_last = session.cli_session_id == null and isAutoResumeEnabled(),
                .permission_mode = @tagName(session.permission_mode),
                .model = session.model,
            }) catch |err| {
                log.err("Failed to start Claude Code: {}", .{err});
                session.bridge = null;
                try self.sendEngineText(session_id, engine, "Failed to start Claude Code. Please ensure it is installed and in PATH.");
                return "error";
            };
            bridge_started = true;
        }

        if (bridge_started) {
            const bridge_start_ms = timer.read() / std.time.ns_per_ms;
            log.info("Claude bridge started in {d}ms", .{bridge_start_ms});
        }

        session.bridge.?.sendPrompt(prompt) catch |err| {
            log.warn("Claude Code sendPrompt failed ({}), restarting", .{err});
            session.bridge.?.stop();
            session.bridge.?.start(.{
                .resume_session_id = session.cli_session_id,
                .continue_last = session.cli_session_id == null and isAutoResumeEnabled(),
                .permission_mode = @tagName(session.permission_mode),
                .model = session.model,
            }) catch |start_err| {
                log.err("Failed to restart Claude Code: {}", .{start_err});
                session.bridge = null;
                try self.sendEngineText(session_id, engine, "Failed to start Claude Code. Please ensure it is installed and in PATH.");
                return "error";
            };
            try session.bridge.?.sendPrompt(prompt);
        };
        const prompt_sent_ms = timer.read() / std.time.ns_per_ms;
        log.info("Claude prompt sent at {d}ms", .{prompt_sent_ms});

        var stop_reason: []const u8 = "end_turn";
        const cli_bridge = &session.bridge.?;
        var first_response_ms: u64 = 0;
        var msg_count: u32 = 0;

        while (true) {
            if (session.cancelled) {
                stop_reason = "cancelled";
                break;
            }

            var msg = cli_bridge.readMessage() catch |err| {
                log.err("Failed to read Claude Code message: {}", .{err});
                break;
            } orelse break;
            defer msg.deinit();

            msg_count += 1;
            const msg_time_ms = timer.read() / std.time.ns_per_ms;
            if (first_response_ms == 0) first_response_ms = msg_time_ms;
            log.debug("Claude msg #{d} ({s}) at {d}ms", .{ msg_count, @tagName(msg.type), msg_time_ms });

            switch (msg.type) {
                .assistant => {
                    if (msg.getContent()) |content| {
                        if (first_response_ms == 0) {
                            first_response_ms = msg_time_ms;
                        }
                        try self.sendEngineText(session_id, engine, content);
                    }

                    if (msg.getToolUse()) |tool| {
                        try self.handleEngineToolCall(
                            session,
                            session_id,
                            engine,
                            tool.name,
                            tool.name,
                            tool.id,
                            mapToolKind(tool.name),
                            tool.input,
                        );
                    }

                    if (msg.getToolResult()) |tool_result| {
                        const status: protocol.SessionUpdate.ToolCallStatus = if (tool_result.is_error) .failed else .completed;
                        try self.handleEngineToolResult(session_id, engine, tool_result.id, tool_result.content, status);
                    }
                },
                .user => {
                    if (msg.getToolResult()) |tool_result| {
                        const status: protocol.SessionUpdate.ToolCallStatus = if (tool_result.is_error) .failed else .completed;
                        try self.handleEngineToolResult(session_id, engine, tool_result.id, tool_result.content, status);
                    }
                },
                .result => {
                    if (msg.getStopReason()) |reason| {
                        stop_reason = mapCliStopReason(reason);
                    }
                    break;
                },
                .stream_event => {
                    if (msg.getStreamEventType()) |event_type| {
                        switch (event_type) {
                            .message_start => stream_prefix_pending = true,
                            .message_stop => stream_prefix_pending = false,
                            else => {},
                        }
                    }
                    if (msg.getStreamTextDelta()) |text| {
                        if (first_response_ms == 0) {
                            first_response_ms = msg_time_ms;
                            log.info("First Claude stream response at {d}ms", .{msg_time_ms});
                        }
                        if (stream_prefix_pending) {
                            try self.sendEngineTextPrefix(session_id, engine);
                            stream_prefix_pending = false;
                        }
                        try self.sendEngineTextRaw(session_id, text);
                    }
                    if (msg.getStreamThinkingDelta()) |thinking| {
                        try self.sendEngineThought(session_id, engine, thinking);
                    }
                },
                .system => {
                    if (msg.getSystemSubtype()) |subtype| {
                        switch (subtype) {
                            .init => {
                                if (msg.getInitInfo()) |init_info| {
                                    if (init_info.slash_commands) |cmds| {
                                        try self.sendAvailableCommands(session_id, cmds);
                                    }
                                    if (init_info.session_id) |cli_sid| {
                                        if (session.cli_session_id == null) {
                                            session.cli_session_id = self.allocator.dupe(u8, cli_sid) catch |err| blk: {
                                                log.warn("Failed to capture Claude session ID: {}", .{err});
                                                break :blk null;
                                            };
                                            if (session.cli_session_id != null) {
                                                log.info("Captured Claude session ID: {s}", .{cli_sid});
                                            }
                                        }
                                    }
                                }
                                if (msg.getContent()) |content| {
                                    if (isAuthRequiredContent(content)) {
                                        stop_reason = try self.handleAuthRequired(session_id, session, engine);
                                        break;
                                    }
                                }
                            },
                            .auth_required => {
                                if (msg.getContent()) |content| {
                                    if (isAuthRequiredContent(content)) {
                                        stop_reason = try self.handleAuthRequired(session_id, session, engine);
                                        break;
                                    }
                                }
                            },
                            .hook_response => {},
                        }
                    } else {
                        if (msg.getContent()) |content| {
                            try self.sendEngineText(session_id, engine, content);
                        }
                    }
                },
                else => {},
            }
        }

        const total_ms = timer.read() / std.time.ns_per_ms;
        log.info("Claude prompt complete: {d} msgs, first response at {d}ms, total {d}ms", .{ msg_count, first_response_ms, total_ms });

        return stop_reason;
    }

    fn runCodexPrompt(self: *Agent, session: *Session, session_id: []const u8, prompt: []const u8) ![]const u8 {
        var timer = std.time.Timer.start() catch unreachable;
        const engine = Engine.codex;

        if (session.codex_bridge == null) {
            session.codex_bridge = CodexBridge.init(self.allocator, session.cwd);
        }

        if (session.codex_bridge.?.process == null) {
            session.codex_bridge.?.start(.{
                .resume_session_id = session.codex_session_id,
                .model = null,
            }) catch |err| {
                log.err("Failed to start Codex: {}", .{err});
                session.codex_bridge = null;
                try self.sendEngineText(session_id, engine, "Failed to start Codex. Please ensure it is installed and in PATH.");
                return "error";
            };
            const start_ms = timer.read() / std.time.ns_per_ms;
            log.info("Codex bridge started in {d}ms", .{start_ms});
        }

        session.codex_bridge.?.sendPrompt(prompt) catch |err| {
            log.warn("Codex sendPrompt failed ({}), restarting", .{err});
            session.codex_bridge.?.stop();
            session.codex_bridge = CodexBridge.init(self.allocator, session.cwd);
            session.codex_bridge.?.start(.{
                .resume_session_id = session.codex_session_id,
                .model = null,
            }) catch |start_err| {
                log.err("Failed to restart Codex: {}", .{start_err});
                session.codex_bridge = null;
                try self.sendEngineText(session_id, engine, "Failed to start Codex. Please ensure it is installed and in PATH.");
                return "error";
            };
            try session.codex_bridge.?.sendPrompt(prompt);
        };
        const codex_bridge = &session.codex_bridge.?;
        const prompt_sent_ms = timer.read() / std.time.ns_per_ms;
        log.info("Codex prompt sent at {d}ms", .{prompt_sent_ms});

        var first_response_ms: u64 = 0;
        var msg_count: u32 = 0;

        while (true) {
            if (session.cancelled) return "cancelled";

            var msg = codex_bridge.readMessage() catch |err| {
                log.err("Failed to read Codex message: {}", .{err});
                break;
            } orelse {
                codex_bridge.stop();
                session.codex_bridge = null;
                break;
            };
            defer msg.deinit();

            msg_count += 1;
            const msg_time_ms = timer.read() / std.time.ns_per_ms;
            if (first_response_ms == 0) first_response_ms = msg_time_ms;

            if (msg.getSessionId()) |sid| {
                if (session.codex_session_id == null) {
                    session.codex_session_id = self.allocator.dupe(u8, sid) catch |err| blk: {
                        log.warn("Failed to capture Codex session ID: {}", .{err});
                        break :blk null;
                    };
                    if (session.codex_session_id != null) {
                        log.info("Captured Codex session ID: {s}", .{sid});
                    }
                }
            }

            if (msg.getToolCall()) |tool| {
                try self.handleEngineToolCall(
                    session,
                    session_id,
                    engine,
                    "Bash",
                    tool.command,
                    tool.id,
                    .command,
                    null,
                );
                continue;
            }

            if (msg.getToolResult()) |tool_result| {
                const status: protocol.SessionUpdate.ToolCallStatus = if (tool_result.exit_code) |code|
                    (if (code == 0) .completed else .failed)
                else
                    .completed;
                try self.handleEngineToolResult(session_id, engine, tool_result.id, tool_result.content, status);
                continue;
            }

            if (msg.getThought()) |text| {
                if (first_response_ms == 0) first_response_ms = msg_time_ms;
                try self.sendEngineThought(session_id, engine, text);
                continue;
            }

            if (msg.getText()) |text| {
                if (first_response_ms == 0) first_response_ms = msg_time_ms;
                try self.sendEngineText(session_id, engine, text);
                continue;
            }

            if (msg.isTurnCompleted()) break;
        }

        const total_ms = timer.read() / std.time.ns_per_ms;
        log.info("Codex prompt complete: {d} msgs, first response at {d}ms, total {d}ms", .{ msg_count, first_response_ms, total_ms });
        return "end_turn";
    }

    fn sendEngineText(self: *Agent, session_id: []const u8, engine: Engine, text: []const u8) !void {
        const tagged = try self.tagText(engine, text);
        defer self.allocator.free(tagged);
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = tagged },
        });
    }

    fn sendEngineTextRaw(self: *Agent, session_id: []const u8, text: []const u8) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = text },
        });
    }

    fn sendEngineTextPrefix(self: *Agent, session_id: []const u8, engine: Engine) !void {
        const prefix = enginePrefix(engine);
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = prefix },
        });
    }

    fn sendEngineThought(self: *Agent, session_id: []const u8, engine: Engine, text: []const u8) !void {
        const tagged = try self.tagText(engine, text);
        defer self.allocator.free(tagged);
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_thought_chunk,
            .content = .{ .type = "text", .text = tagged },
        });
    }

    fn sendEngineToolCall(
        self: *Agent,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        tool_name: []const u8,
        kind: protocol.SessionUpdate.ToolKind,
        raw_input: ?std.json.Value,
    ) !void {
        const tagged_title = try self.tagText(engine, tool_name);
        defer self.allocator.free(tagged_title);
        const tagged_id = try self.tagToolId(engine, tool_id);
        defer self.allocator.free(tagged_id);
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .tool_call,
            .toolCallId = tagged_id,
            .title = tagged_title,
            .kind = kind,
            .status = .pending,
            .rawInput = raw_input,
        });
    }

    fn sendEngineToolResult(
        self: *Agent,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        content: ?[]const u8,
        status: protocol.SessionUpdate.ToolCallStatus,
    ) !void {
        const tagged_id = try self.tagToolId(engine, tool_id);
        defer self.allocator.free(tagged_id);

        var tagged_content: ?[]const u8 = null;
        if (content) |text| {
            tagged_content = try self.tagText(engine, text);
        }
        defer if (tagged_content) |text| self.allocator.free(text);

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .tool_call_update,
            .toolCallId = tagged_id,
            .status = status,
            .content = if (tagged_content) |text| .{ .type = "text", .text = text } else null,
        });
    }

    fn handleEngineToolCall(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        engine: Engine,
        permission_name: []const u8,
        display_name: []const u8,
        tool_id: []const u8,
        kind: protocol.SessionUpdate.ToolKind,
        raw_input: ?std.json.Value,
    ) !void {
        if (!session.isToolAllowed(permission_name)) {
            log.warn("Tool {s} denied by settings", .{permission_name});
            try self.sendEngineText(session_id, engine, "Tool execution blocked by settings.");
            return;
        }
        try self.sendEngineToolCall(session_id, engine, tool_id, display_name, kind, raw_input);
    }

    fn handleEngineToolResult(
        self: *Agent,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        content: ?[]const u8,
        status: protocol.SessionUpdate.ToolCallStatus,
    ) !void {
        try self.sendEngineToolResult(session_id, engine, tool_id, content, status);
    }

    fn tagText(self: *Agent, engine: Engine, text: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ engineLabel(engine), text });
    }

    fn tagToolId(self: *Agent, engine: Engine, tool_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ engineLabel(engine), tool_id });
    }

    fn handleCancel(self: *Agent, request: jsonrpc.Request) !void {
        const parsed = std.json.parseFromValue(CancelParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse cancel params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        if (self.sessions.get(parsed.value.sessionId)) |session| {
            session.cancelled = true;
            if (session.bridge) |*b| {
                b.stop();
            }
            if (session.codex_bridge) |*b| {
                b.stop();
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
        errdefer self.allocator.destroy(session);
        const sid_copy = try self.allocator.dupe(u8, params.sessionId);
        errdefer self.allocator.free(sid_copy);
        const cwd_copy = try self.allocator.dupe(u8, params.cwd);
        errdefer self.allocator.free(cwd_copy);

        session.* = .{
            .id = sid_copy,
            .cwd = cwd_copy,
        };
        try self.sessions.put(sid_copy, session);

        log.info("Resumed session {s}", .{sid_copy});

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try result.object.put("sessionId", .{ .string = sid_copy });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    /// Handle authentication required - notify user and stop bridge
    fn handleAuthRequired(self: *Agent, session_id: []const u8, session: *Session, engine: Engine) ![]const u8 {
        log.warn("Auth required for session {s}", .{session_id});
        try self.sendEngineText(session_id, engine, "Authentication required. Please run `claude /login` in your terminal, then try again.");
        if (session.bridge) |*b| {
            b.stop();
        }
        session.bridge = null;
        return "auth_required";
    }

    /// Handle /version command
    fn handleVersionCommand(self: *Agent, request: jsonrpc.Request, session_id: []const u8) !void {
        const version_msg = std.fmt.comptimePrint("Banjo {s} - ACP Agent for Claude Code + Codex", .{version});
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = version_msg },
        });

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try result.object.put("stopReason", .{ .string = "end_turn" });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    const Command = enum { version, note, notes, setup, explain };
    const command_map = std.StaticStringMap(Command).initComptime(.{
        .{ "version", .version },
        .{ "note", .note },
        .{ "notes", .notes },
        .{ "setup", .setup },
        .{ "explain", .explain },
    });

    /// Dispatch slash commands. Returns modified prompt to pass to CLI, or null if fully handled.
    fn dispatchCommand(self: *Agent, request: jsonrpc.Request, session: *Session, session_id: []const u8, text: []const u8, resource: ?ResourceData) ?[]const u8 {
        // Extract command name: "/cmd arg" -> "cmd"
        const after_slash = text[1..];
        const space_idx = std.mem.indexOfScalar(u8, after_slash, ' ') orelse after_slash.len;
        const cmd_name = after_slash[0..space_idx];

        const command = command_map.get(cmd_name) orelse return text; // Not our command, pass through to CLI

        switch (command) {
            .version => {
                self.handleVersionCommand(request, session_id) catch |err| {
                    log.err("Version command failed: {}", .{err});
                    self.sendErrorAndEnd(request, session_id, "Version command failed") catch {};
                };
                return null; // Fully handled
            },
            .note, .notes, .setup => {
                self.handleNotesCommand(request, session_id, session.cwd, text) catch |err| {
                    log.err("Notes command failed: {}", .{err});
                    self.sendErrorAndEnd(request, session_id, "Notes command failed") catch {};
                };
                return null; // Fully handled
            },
            .explain => {
                // Get summary from Claude and insert as note comment
                if (resource) |r| {
                    self.handleExplainCommand(request, session, session_id, r) catch |err| {
                        log.err("Explain command failed: {}", .{err});
                        self.sendErrorAndEnd(request, session_id, "Explain command failed") catch {};
                    };
                    return null;
                }
                // No valid resource found - show usage
                self.sendSessionUpdate(session_id, .{
                    .sessionUpdate = .agent_message_chunk,
                    .content = .{ .type = "text", .text = "Usage: `/explain` with a code reference\n\n1. Select code in editor\n2. Press **Cmd+>** to add reference\n3. Type `/explain` and send" },
                }) catch |err| {
                    log.err("Failed to send usage message: {}", .{err});
                };
                self.sendEndTurn(request) catch |err| {
                    log.err("Failed to send end turn: {}", .{err});
                };
                return null;
            },
        }
    }

    /// Decoded file URI result (path may be allocated)
    const FileUri = struct {
        path: []const u8,
        line: u32,
        allocated: bool = false,

        fn deinit(self: *const FileUri, allocator: Allocator) void {
            if (self.allocated) allocator.free(self.path);
        }
    };

    /// Parse file:// URI into path and line number, with URL decoding
    fn parseFileUri(allocator: Allocator, uri: []const u8) ?FileUri {
        if (!std.mem.startsWith(u8, uri, "file:///")) return null;
        const path_start = 7; // skip "file://"
        const hash_idx = std.mem.indexOfScalar(u8, uri, '#') orelse uri.len;
        const raw_path = uri[path_start..hash_idx];
        if (raw_path.len == 0) return null;

        // URL decode path (handle %XX sequences)
        const path = if (std.mem.indexOf(u8, raw_path, "%")) |_| blk: {
            var decoded: std.ArrayListUnmanaged(u8) = .empty;
            errdefer decoded.deinit(allocator);
            var i: usize = 0;
            while (i < raw_path.len) {
                if (raw_path[i] == '%' and i + 2 < raw_path.len) {
                    const hex = raw_path[i + 1 .. i + 3];
                    if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                        decoded.append(allocator, byte) catch return null;
                        i += 3;
                        continue;
                    } else |_| {}
                }
                decoded.append(allocator, raw_path[i]) catch return null;
                i += 1;
            }
            break :blk decoded.toOwnedSlice(allocator) catch return null;
        } else raw_path;

        var line: u32 = 1;
        if (hash_idx + 2 < uri.len and uri[hash_idx + 1] == 'L') {
            const line_part = uri[hash_idx + 2 ..];
            const colon_idx = std.mem.indexOfScalar(u8, line_part, ':') orelse line_part.len;
            line = std.fmt.parseInt(u32, line_part[0..colon_idx], 10) catch 1;
        }
        return .{ .path = path, .line = line, .allocated = std.mem.indexOf(u8, raw_path, "%") != null };
    }

    /// Handle /explain command: get summary from Claude and insert as note comment
    fn handleExplainCommand(self: *Agent, request: jsonrpc.Request, session: *Session, session_id: []const u8, resource: ResourceData) !void {
        const comments = @import("../notes/comments.zig");

        // Initialize plan
        var plan_entries = [_]protocol.SessionUpdate.PlanEntry{
            .{ .id = "1", .content = "Read selected code", .status = .in_progress },
            .{ .id = "2", .content = "Generate explanation", .status = .pending },
            .{ .id = "3", .content = "Insert note comment", .status = .pending },
        };
        try self.sendPlan(session_id, &plan_entries);

        // Parse URI
        const uri_info = parseFileUri(self.allocator, resource.uri) orelse {
            return self.sendErrorAndEnd(request, session_id, "Invalid file URI");
        };
        defer uri_info.deinit(self.allocator);

        // Security: validate path is within project directory (resolve symlinks)
        const real_path = std.fs.cwd().realpathAlloc(self.allocator, uri_info.path) catch {
            return self.sendErrorAndEnd(request, session_id, "Invalid file path");
        };
        defer self.allocator.free(real_path);

        const real_cwd = std.fs.cwd().realpathAlloc(self.allocator, session.cwd) catch session.cwd;
        defer if (real_cwd.ptr != session.cwd.ptr) self.allocator.free(real_cwd);

        const in_project = std.mem.startsWith(u8, real_path, real_cwd) and
            (real_path.len == real_cwd.len or real_path[real_cwd.len] == '/');
        if (!in_project) {
            log.warn("Path traversal attempt: {s} not in {s}", .{ real_path, real_cwd });
            return self.sendErrorAndEnd(request, session_id, "File must be within project directory");
        }

        // Get code content from resource
        const code = resource.text orelse {
            return self.sendErrorAndEnd(request, session_id, "No code content in reference");
        };

        // Report reading file
        const filename = std.fs.path.basename(uri_info.path);
        const read_title = try std.fmt.allocPrint(self.allocator, "Reading {s}", .{filename});
        defer self.allocator.free(read_title);
        const read_tool_id = try self.reportToolStart(session_id, read_title, .read);
        defer self.allocator.free(read_tool_id);
        try self.reportToolComplete(session_id, read_tool_id, true);

        // Step 1 complete: code read from resource
        plan_entries[0].status = .completed;
        plan_entries[1].status = .in_progress;
        try self.sendPlan(session_id, &plan_entries);

        // Build prompt asking for paragraph summary
        const ext = std.fs.path.extension(uri_info.path);
        const lang = if (ext.len > 1) ext[1..] else "code";
        const prompt = try std.fmt.allocPrint(self.allocator,
            \\Write a brief paragraph explaining what this {s} code does. Be concise but thorough.
            \\Respond with ONLY the explanation paragraph, no code blocks or formatting.
            \\
            \\```{s}
            \\{s}
            \\```
        , .{ lang, lang, code });
        defer self.allocator.free(prompt);

        // Report generating explanation
        const explain_tool_id = try self.reportToolStart(session_id, "Generating explanation", .other);
        defer self.allocator.free(explain_tool_id);

        // Send prompt and collect response
        const cli_bridge = try self.ensureBridge(session);
        try cli_bridge.sendPrompt(prompt);

        var summary: std.ArrayListUnmanaged(u8) = .empty;
        defer summary.deinit(self.allocator);

        const max_summary_size = 64 * 1024; // 64KB limit for summary
        while (true) {
            var msg = cli_bridge.readMessage() catch break orelse break;
            defer msg.deinit();

            switch (msg.type) {
                .assistant => if (msg.getContent()) |content| {
                    if (summary.items.len + content.len > max_summary_size) break;
                    try summary.appendSlice(self.allocator, content);
                },
                .stream_event => if (msg.getStreamTextDelta()) |text| {
                    if (summary.items.len + text.len > max_summary_size) break;
                    try summary.appendSlice(self.allocator, text);
                },
                .result => break,
                else => {},
            }
        }

        if (summary.items.len == 0) {
            try self.reportToolComplete(session_id, explain_tool_id, false);
            return self.sendErrorAndEnd(request, session_id, "Could not get explanation from Claude");
        }
        try self.reportToolComplete(session_id, explain_tool_id, true);

        // Step 2 complete: explanation generated
        plan_entries[1].status = .completed;
        plan_entries[2].status = .in_progress;
        try self.sendPlan(session_id, &plan_entries);

        // Generate note comment
        const note_id = comments.generateNoteId();
        const comment_prefix = comments.getCommentPrefix(uri_info.path);

        // Format summary (replace newlines with spaces)
        const trimmed = std.mem.trim(u8, summary.items, " \t\n\r");
        var formatted = try self.allocator.alloc(u8, trimmed.len);
        defer self.allocator.free(formatted);
        for (trimmed, 0..) |c, i| {
            formatted[i] = if (c == '\n') ' ' else c;
        }

        const note_comment = try std.fmt.allocPrint(self.allocator, "{s} @banjo[{s}] {s}\n", .{
            comment_prefix, &note_id, formatted,
        });
        defer self.allocator.free(note_comment);

        // Report inserting note
        const insert_tool_id = try self.reportToolStart(session_id, "Inserting note", .write);
        defer self.allocator.free(insert_tool_id);

        // Insert comment at line (use real_path, not uri_info.path, to prevent symlink bypass)
        comments.insertAtLine(self.allocator, real_path, uri_info.line, note_comment) catch |err| {
            log.err("insertAtLine failed: {}", .{err});
            try self.reportToolComplete(session_id, insert_tool_id, false);
            return self.sendErrorAndEnd(request, session_id, "Could not write to file");
        };
        try self.reportToolComplete(session_id, insert_tool_id, true);

        // Step 3 complete: note inserted
        plan_entries[2].status = .completed;
        try self.sendPlan(session_id, &plan_entries);

        // Send success message
        const success_msg = try std.fmt.allocPrint(self.allocator, "Added note `{s}` at {s}:{d}", .{
            &note_id, std.fs.path.basename(uri_info.path), uri_info.line,
        });
        defer self.allocator.free(success_msg);

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = success_msg },
        });
        try self.sendEndTurn(request);
    }

    /// Handle /note, /notes, and /setup commands
    fn handleNotesCommand(self: *Agent, request: jsonrpc.Request, session_id: []const u8, cwd: []const u8, command: []const u8) !void {
        // Determine tool title and kind based on command
        const is_setup = std.mem.startsWith(u8, command, "/setup");
        const title: []const u8 = if (is_setup) "Configuring Zed settings" else "Scanning project for notes";
        const kind: protocol.SessionUpdate.ToolKind = if (is_setup) .write else .read;

        // Report tool start
        const tool_id = try self.reportToolStart(session_id, title, kind);
        defer self.allocator.free(tool_id);

        // Execute command with project root
        var cmd_result = notes_commands.executeCommand(self.allocator, cwd, command) catch {
            try self.reportToolComplete(session_id, tool_id, false);
            try self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{ .type = "text", .text = "Failed to execute notes command" },
            });
            var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
            defer result.object.deinit();
            try result.object.put("stopReason", .{ .string = "error" });
            try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
            return;
        };
        defer cmd_result.deinit(self.allocator);

        // Report tool completion
        try self.reportToolComplete(session_id, tool_id, cmd_result.success);

        // Send response
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = cmd_result.message },
        });

        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try result.object.put("stopReason", .{ .string = if (cmd_result.success) "end_turn" else "error" });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    /// Auto-setup LSP if .zed/settings.json doesn't exist. Returns true if setup was performed.
    fn autoSetupLspIfNeeded(self: *Agent, cwd: []const u8) !bool {
        // Only run for absolute paths (skip "." or relative paths in tests)
        if (cwd.len == 0 or cwd[0] != '/') {
            log.debug("Auto-setup: skipping for non-absolute path: {s}", .{cwd});
            return false;
        }

        // Check if .zed/settings.json already exists
        const settings_path = try std.fs.path.join(self.allocator, &.{ cwd, ".zed", "settings.json" });
        defer self.allocator.free(settings_path);

        std.fs.accessAbsolute(settings_path, .{}) catch {
            // Doesn't exist - run setup
            log.info("Auto-setup: creating .zed/settings.json for {s}", .{cwd});
            var result = try notes_commands.executeCommand(self.allocator, cwd, "/setup");
            defer result.deinit(self.allocator);

            if (result.success) {
                log.info("Auto-setup: LSP enabled for project", .{});
                return true;
            } else {
                log.warn("Auto-setup: {s}", .{result.message});
                return false;
            }
        };

        // Already exists - nothing to do
        log.debug("Auto-setup: .zed/settings.json already exists", .{});
        return false;
    }

    /// Agent slash commands (handled locally, not forwarded to CLI)
    const slash_commands = [_]protocol.SlashCommand{
        .{ .name = "explain", .description = "Summarize selected code as a note comment" },
        .{ .name = "setup", .description = "Configure Zed for banjo LSP integration" },
        .{ .name = "notes", .description = "List all notes in the project" },
        .{ .name = "note", .description = "Note management commands" },
        .{ .name = "version", .description = "Show banjo version" },
        .{ .name = "claude", .description = "Route prompt to Claude only" },
        .{ .name = "codex", .description = "Route prompt to Codex only" },
        .{ .name = "both", .description = "Route prompt to Claude then Codex" },
    };

    /// Commands filtered from CLI (unsupported in stream-json mode, handled via authMethods)
    const unsupported_commands = [_][]const u8{ "login", "logout", "cost", "context" };

    /// Common Claude Code slash commands (static fallback, CLI provides full list on first prompt)
    const common_cli_commands = [_]protocol.SlashCommand{
        .{ .name = "model", .description = "Show current model" },
        .{ .name = "compact", .description = "Compact conversation" },
        .{ .name = "review", .description = "Code review" },
    };

    /// Combined commands for initial session (before CLI provides its list)
    const initial_commands = slash_commands ++ common_cli_commands;

    /// Check if command is unsupported
    fn isUnsupportedCommand(name: []const u8) bool {
        for (unsupported_commands) |cmd| {
            if (std.mem.eql(u8, name, cmd)) return true;
        }
        return false;
    }

    /// Check if command is ours (to avoid duplicates with CLI)
    fn isOurCommand(name: []const u8) bool {
        for (slash_commands) |cmd| {
            if (std.mem.eql(u8, name, cmd.name)) return true;
        }
        return false;
    }

    /// Send available_commands_update with CLI commands + agent commands
    fn sendAvailableCommands(self: *Agent, session_id: []const u8, cli_commands: []const []const u8) !void {
        // Build command list: agent commands + CLI commands (filtered)
        var commands: std.ArrayList(protocol.SlashCommand) = .empty;
        defer commands.deinit(self.allocator);

        // Add agent commands first
        for (&slash_commands) |cmd| {
            try commands.append(self.allocator, cmd);
        }

        // Add CLI commands, filtering unsupported and duplicates
        for (cli_commands) |name| {
            if (isUnsupportedCommand(name) or isOurCommand(name)) continue;
            // Check if already added (CLI might send duplicates)
            const already_added = for (commands.items) |cmd| {
                if (std.mem.eql(u8, cmd.name, name)) break true;
            } else false;
            if (!already_added) {
                try commands.append(self.allocator, .{ .name = name, .description = "" });
            }
        }

        log.info("Sending {d} available commands to client", .{commands.items.len});

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .available_commands_update,
            .availableCommands = commands.items,
        });
    }

    /// Send end_turn response for a request
    fn sendEndTurn(self: *Agent, request: jsonrpc.Request) !void {
        var result = std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        defer result.object.deinit();
        try result.object.put("stopReason", .{ .string = "end_turn" });
        try self.writer.writeResponse(jsonrpc.Response.success(request.id, result));
    }

    /// Send error message and end turn (common pattern)
    fn sendErrorAndEnd(self: *Agent, request: jsonrpc.Request, session_id: []const u8, msg: []const u8) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = msg },
        });
        try self.sendEndTurn(request);
    }

    /// Send plan progress update
    fn sendPlan(self: *Agent, session_id: []const u8, entries: []const protocol.SessionUpdate.PlanEntry) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .plan,
            .entries = entries,
        });
    }

    /// Ensure bridge is started, return it
    fn ensureBridge(self: *Agent, session: *Session) !*Bridge {
        if (session.bridge == null) {
            session.bridge = Bridge.init(self.allocator, session.cwd);
            try session.bridge.?.start(.{
                .resume_session_id = session.cli_session_id,
                .permission_mode = @tagName(session.permission_mode),
                .model = session.model,
            });
        }
        return &session.bridge.?;
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

    //
    // Tool Call Reporting
    //

    /// Generate a unique tool call ID like "banjo_tc_1"
    fn generateToolCallId(self: *Agent) ![]const u8 {
        const id = self.next_tool_call_id;
        self.next_tool_call_id += 1;
        return std.fmt.allocPrint(self.allocator, "banjo_tc_{d}", .{id});
    }

    /// Report tool start with in_progress status, returns the tool call ID
    fn reportToolStart(self: *Agent, session_id: []const u8, title: []const u8, kind: protocol.SessionUpdate.ToolKind) ![]const u8 {
        const tool_id = try self.generateToolCallId();
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .tool_call,
            .toolCallId = tool_id,
            .title = title,
            .kind = kind,
            .status = .in_progress,
        });
        return tool_id;
    }

    /// Report tool completion with success or failure status
    fn reportToolComplete(self: *Agent, session_id: []const u8, tool_id: []const u8, success: bool) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .tool_call_update,
            .toolCallId = tool_id,
            .status = if (success) .completed else .failed,
        });
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

    /// Get first line of output (for parsing response when notification follows)
    pub fn getFirstLine(self: *TestWriter) []const u8 {
        const output = self.output.items;
        if (std.mem.indexOf(u8, output, "\n")) |idx| {
            return output[0..idx];
        }
        return output;
    }
};

test "isAutoResumeEnabled returns true by default" {
    // When BANJO_AUTO_RESUME is not set (typical case), should return true
    // The env var may or may not be set in CI, so we just verify the function works
    _ = isAutoResumeEnabled();
}

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

test "Agent handleRequest - initialize rejects wrong protocol version" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // Build params with wrong protocol version
    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("protocolVersion", .{ .integer = 999 }); // Wrong version

    const request = jsonrpc.Request{
        .method = "initialize",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    // Parse the response
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be an error response
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.InvalidParams), err.get("code").?.integer);
    try testing.expectEqualStrings("Unsupported protocol version", err.get("message").?.string);
}

test "Agent handleRequest - initialize accepts correct protocol version" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // Build params with correct protocol version
    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("protocolVersion", .{ .integer = protocol.ProtocolVersion });

    const request = jsonrpc.Request{
        .method = "initialize",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    // Parse the response
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be a success response
    try testing.expect(parsed.value.object.get("result") != null);
    try testing.expect(parsed.value.object.get("error") == null);
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

    // Check response (first line, notification follows)
    try testing.expect(tw.getOutput().len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getFirstLine(), .{});
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

    // Parse the session ID from response (first line, notification follows)
    const create_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getFirstLine(), .{});
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

    // Get the session ID (first line, notification follows)
    const create_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getFirstLine(), .{});
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

test "property: parseRoutePrefix strips routing command and preserves payload" {
    try quickcheck.check(struct {
        fn prop(args: struct { prefix: u2, payload: [32]u8, len: u5 }) bool {
            const prefix_str = switch (args.prefix) {
                0 => "/claude",
                1 => "/codex",
                else => "/both",
            };
            const route = switch (args.prefix) {
                0 => Route.claude,
                1 => Route.codex,
                else => Route.both,
            };

            const payload_len = @as(usize, args.len) % args.payload.len;
            var buf: [64]u8 = undefined;
            var idx: usize = 0;
            std.mem.copyForwards(u8, buf[idx..][0..prefix_str.len], prefix_str);
            idx += prefix_str.len;
            buf[idx] = ' ';
            idx += 1;
            std.mem.copyForwards(u8, buf[idx..][0..payload_len], args.payload[0..payload_len]);
            idx += payload_len;

            const input = buf[0..idx];
            const result = parseRoutePrefix(input, .both);
            var expected_start: usize = 0;
            while (expected_start < payload_len and (args.payload[expected_start] == ' ' or args.payload[expected_start] == '\t')) {
                expected_start += 1;
            }
            return result.consumed and result.route == route and std.mem.eql(u8, result.prompt, args.payload[expected_start..payload_len]);
        }
    }.prop, .{});
}

test "parseRoutePrefix ignores non-command prefixes" {
    const input = "/claudeX hello";
    const result = parseRoutePrefix(input, .both);
    try testing.expect(!result.consumed);
    try testing.expectEqual(Route.both, result.route);
    try testing.expectEqualStrings(input, result.prompt);
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

    // Get the session ID (first line, notification follows)
    const create_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getFirstLine(), .{});
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

// =============================================================================
// Error Path Tests
// =============================================================================

test "Agent handleRequest - prompt missing sessionId" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // Empty params - missing sessionId
    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();

    const request = jsonrpc.Request{
        .method = "session/prompt",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be an error response
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.InvalidParams), err.get("code").?.integer);
}

test "Agent handleRequest - prompt session not found" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "nonexistent-session" });

    const request = jsonrpc.Request{
        .method = "session/prompt",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be an error response
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.InvalidParams), err.get("code").?.integer);
    try testing.expectEqualStrings("Session not found", err.get("message").?.string);
}

test "Agent handleRequest - setMode missing params" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // Empty params
    const request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 1 },
        .params = null,
    };

    try agent.handleRequest(request);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be an error response
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.InvalidParams), err.get("code").?.integer);
}

test "Agent handleRequest - resumeSession missing params" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    // Empty params - missing sessionId
    const request = jsonrpc.Request{
        .method = "unstable_resumeSession",
        .id = .{ .number = 1 },
        .params = null,
    };

    try agent.handleRequest(request);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be an error response
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, jsonrpc.Error.InvalidParams), err.get("code").?.integer);
}

test "Agent handleRequest - authenticate returns success" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "authenticate",
        .id = .{ .number = 1 },
        .params = null,
    };

    try agent.handleRequest(request);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, tw.getOutput(), .{});
    defer parsed.deinit();

    // Should be a success response (empty result object)
    try testing.expect(parsed.value.object.get("result") != null);
    try testing.expect(parsed.value.object.get("error") == null);
}

test "isUnsupportedCommand filters correctly" {
    // These should be filtered
    try testing.expect(Agent.isUnsupportedCommand("login"));
    try testing.expect(Agent.isUnsupportedCommand("logout"));
    try testing.expect(Agent.isUnsupportedCommand("cost"));
    try testing.expect(Agent.isUnsupportedCommand("context"));

    // These should not be filtered
    try testing.expect(!Agent.isUnsupportedCommand("model"));
    try testing.expect(!Agent.isUnsupportedCommand("compact"));
    try testing.expect(!Agent.isUnsupportedCommand("review"));
    try testing.expect(!Agent.isUnsupportedCommand("version"));
}
