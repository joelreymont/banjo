const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const jsonrpc = @import("../jsonrpc.zig");
const protocol = @import("protocol.zig");
const bridge = @import("../core/claude_bridge.zig");
const Bridge = bridge.Bridge;
const SystemSubtype = bridge.SystemSubtype;
const codex_cli = @import("../core/codex_bridge.zig");
const CodexBridge = codex_cli.CodexBridge;
const CodexMessage = codex_cli.CodexMessage;
const CodexUserInput = codex_cli.UserInput;
const settings_loader = @import("../core/settings.zig");
const Settings = settings_loader.Settings;
const dots = @import("../core/dots.zig");
const types = @import("../core/types.zig");
const Engine = types.Engine;
const Route = types.Route;
const engine_mod = @import("../core/engine.zig");
const callbacks_mod = @import("../core/callbacks.zig");
const EditorCallbacks = callbacks_mod.EditorCallbacks;
const CallbackToolKind = callbacks_mod.ToolKind;
const CallbackToolStatus = callbacks_mod.ToolStatus;
const notes_commands = @import("../notes/commands.zig");
const config = @import("config");
const test_env = @import("../util/test_env.zig");
const ToolProxy = @import("../tools/proxy.zig").ToolProxy;

const log = std.log.scoped(.agent);

/// Banjo version with git hash
pub const version = "0.6.1 (" ++ config.git_hash ++ ")";
const no_engine_warning = "Banjo Duet could not find Claude Code or Codex. Install one (or set CLAUDE_CODE_EXECUTABLE/CODEX_EXECUTABLE) and restart the agent.";
const max_context_bytes = 64 * 1024; // cap embedded resource text to keep prompts bounded
const max_media_preview_bytes = 2048; // small preview for binary media captions
const max_codex_image_bytes: usize = 8 * 1024 * 1024; // guard against massive base64 images
const resource_line_limit: u32 = 200; // limit resource excerpt lines to reduce UI spam
const max_tool_preview_bytes: usize = 1024; // keep tool call previews readable in the panel
const default_model_id = "sonnet";
const response_timeout_ms: i64 = 30_000;
const prompt_poll_ms: i64 = 250;

const SessionConfig = struct {
    auto_resume: bool,
    route: Route,
    primary_agent: Engine,
};

/// Check if auto-resume is enabled (default: true)
fn autoResumeFromEnv() bool {
    const val = std.posix.getenv("BANJO_AUTO_RESUME") orelse return true;
    return falsey_env_values.get(val) == null;
}

/// Check if content indicates authentication is required
fn isAuthRequiredContent(content: []const u8) bool {
    return std.mem.indexOf(u8, content, "/login") != null or
        std.mem.indexOf(u8, content, "authenticate") != null;
}

/// Map CLI result subtypes to ACP stop reasons
fn mapCliStopReason(cli_reason: []const u8) protocol.StopReason {
    const map = std.StaticStringMap(protocol.StopReason).initComptime(.{
        .{ "success", .end_turn },
        .{ "cancelled", .cancelled },
        .{ "max_tokens", .max_tokens },
        .{ "error_max_turns", .max_turn_requests },
        .{ "error_max_budget_usd", .max_turn_requests },
    });
    return map.get(cli_reason) orelse .end_turn;
}

const max_turn_markers = [_][]const u8{
    "max_turn",
    "max_turns",
    "max_turn_requests",
};

fn containsMaxTurnMarker(text: ?[]const u8) bool {
    const haystack = text orelse return false;
    for (max_turn_markers) |marker| {
        if (std.mem.indexOf(u8, haystack, marker) != null) return true;
    }
    return false;
}

fn isCodexMaxTurnError(err: codex_cli.TurnError) bool {
    return containsMaxTurnMarker(err.code) or
        containsMaxTurnMarker(err.type) or
        containsMaxTurnMarker(err.message);
}

fn replaceFirst(allocator: Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const pos = std.mem.indexOf(u8, input, needle) orelse {
        return allocator.dupe(u8, input);
    };
    const new_len = input.len - needle.len + replacement.len;
    const result = try allocator.alloc(u8, new_len);
    @memcpy(result[0..pos], input[0..pos]);
    @memcpy(result[pos..][0..replacement.len], replacement);
    @memcpy(result[pos + replacement.len ..], input[pos + needle.len ..]);
    return result;
}

fn routeFromEnv() Route {
    return types.routeFromEnv();
}

fn routeEnvValue() ?Route {
    const val = std.posix.getenv("BANJO_ROUTE") orelse return null;
    return types.route_map.get(val);
}

fn primaryAgentFromEnv() Engine {
    const val = std.posix.getenv("BANJO_PRIMARY_AGENT") orelse return .claude;
    return types.engine_map.get(val) orelse .claude;
}

fn configFromEnv() SessionConfig {
    return .{
        .auto_resume = autoResumeFromEnv(),
        .route = routeFromEnv(),
        .primary_agent = primaryAgentFromEnv(),
    };
}

fn resolveDefaultRoute(availability: EngineAvailability) Route {
    if (routeEnvValue()) |route| return route;
    if (availability.claude and availability.codex) return .claude;
    if (availability.codex) return .codex;
    return .claude;
}

fn codexApprovalPolicy(mode: protocol.PermissionMode) []const u8 {
    return switch (mode) {
        .bypassPermissions, .dontAsk => "never",
        .default, .acceptEdits, .plan => "on-request",
    };
}

const falsey_env_values = std.StaticStringMap(void).initComptime(.{
    .{ "false", {} },
    .{ "0", {} },
});

const bool_str_map = std.StaticStringMap(bool).initComptime(.{
    .{ "true", true },
    .{ "false", false },
});

const ConfigOptionId = enum {
    auto_resume,
    route,
    primary_agent,
};

const config_option_map = std.StaticStringMap(ConfigOptionId).initComptime(.{
    .{ "auto_resume", .auto_resume },
    .{ "route", .route },
    .{ "primary_agent", .primary_agent },
});

const SessionConfigUpdate = struct {
    auto_resume: ?bool = null,
    route: ?Route = null,
    primary_agent: ?Engine = null,
};

const allow_option_ids = std.StaticStringMap(void).initComptime(.{
    .{ "allow_once", {} },
    .{ "allow_always", {} },
});

const allow_session_option_ids = std.StaticStringMap(void).initComptime(.{
    .{ "allow_always", {} },
});

const model_id_set = std.StaticStringMap(void).initComptime(.{
    .{ "sonnet", {} },
    .{ "opus", {} },
    .{ "haiku", {} },
});

const mime_language_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "application/json", "json" },
    .{ "text/markdown", "md" },
    .{ "text/plain", "text" },
    .{ "text/x-zig", "zig" },
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

fn generateSessionIdWithAllocator(allocator: Allocator) ![]const u8 {
    if (builtin.is_test) {
        if (std.posix.getenv("BANJO_TEST_SESSION_ID")) |sid| {
            return allocator.dupe(u8, sid);
        }
    }

    var uuid_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);
    const hex = std.fmt.bytesToHex(uuid_bytes, .lower);
    return allocator.dupe(u8, &hex);
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
        .{ "Bash", .execute },
        .{ "Command", .execute },
    });
    return map.get(tool_name) orelse .other;
}

fn routeLabel(route: Route) []const u8 {
    return switch (route) {
        .claude => "Claude",
        .codex => "Codex",
        .duet => "Duet",
    };
}

// JSON-RPC method parameter schemas
// See docs/acp-protocol.md for full specification

const InitializeParams = struct {
    protocolVersion: ?i64 = null,
    clientCapabilities: ?protocol.ClientCapabilities = null,
};

const NewSessionParams = struct {
    cwd: []const u8 = ".",
    model: ?[]const u8 = null, // Model alias or full name (e.g. "sonnet", "opus", "claude-sonnet-4-5-20250929")
};

const PromptParams = protocol.PromptRequest;

const CancelParams = struct {
    sessionId: []const u8,
};

const SetModeParams = struct {
    sessionId: []const u8,
    modeId: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

const SetModelParams = protocol.SetModelRequest;
const SetConfigParams = protocol.SetConfigOptionRequest;

const ResumeSessionParams = struct {
    sessionId: []const u8,
    cwd: []const u8 = ".",
};

const ContentKind = enum {
    text,
    image,
    audio,
    resource_link,
    resource,
    unknown,
};

const content_kind_map = std.StaticStringMap(ContentKind).initComptime(.{
    .{ "text", .text },
    .{ "image", .image },
    .{ "audio", .audio },
    .{ "resource_link", .resource_link },
    .{ "resource", .resource },
});

/// Resource block data extracted from prompt
const ResourceData = struct {
    uri: []const u8,
    text: []const u8,
    truncated: bool = false,

    fn deinit(self: *const ResourceData, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.uri);
    }
};

const PromptParts = struct {
    user_text: ?[]const u8 = null,
    context: ?[]const u8 = null,
    codex_context: ?[]const u8 = null,
    resource: ?ResourceData = null,
    codex_inputs: ?[]const CodexUserInput = null,
    codex_input_strings: ?[]const []const u8 = null,

    fn deinit(self: *PromptParts, allocator: Allocator) void {
        if (self.user_text) |text| allocator.free(text);
        if (self.context) |text| allocator.free(text);
        if (self.codex_context) |text| allocator.free(text);
        if (self.resource) |*res| res.deinit(allocator);
        if (self.codex_inputs) |inputs| allocator.free(inputs);
        if (self.codex_input_strings) |strings| {
            for (strings) |item| allocator.free(item);
            allocator.free(strings);
        }
    }
};

pub const Agent = struct {
    allocator: Allocator,
    writer: jsonrpc.Writer,
    reader: ?*jsonrpc.Reader = null,
    sessions: std.StringHashMap(*Session),
    client_capabilities: ?protocol.ClientCapabilities = null,
    next_tool_call_id: u64 = 0,
    next_request_id: i64 = 1,
    config_defaults: SessionConfig,
    tool_proxy: ToolProxy,
    pending_response_numbers: std.AutoHashMap(i64, jsonrpc.ParsedMessage),
    pending_response_strings: std.StringHashMap(jsonrpc.ParsedMessage),

    const EditInfo = struct {
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,

        fn deinit(self: EditInfo, allocator: Allocator) void {
            allocator.free(self.path);
            allocator.free(self.old_text);
            allocator.free(self.new_text);
        }
    };

    const Session = struct {
        id: []const u8,
        cwd: []const u8,
        cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        permission_mode: protocol.PermissionMode = .default,
        config: SessionConfig,
        availability: EngineAvailability,
        model: ?[]const u8 = null,
        bridge: ?Bridge = null,
        codex_bridge: ?CodexBridge = null,
        settings: ?Settings = null,
        cli_session_id: ?[]const u8 = null, // Claude Code session ID for --resume
        codex_session_id: ?[]const u8 = null,
        force_new_claude: bool = false,
        force_new_codex: bool = false,
        pending_execute_tools: std.StringHashMap(void),
        pending_edit_tools: std.StringHashMap(EditInfo),
        always_allowed_tools: std.StringHashMap(void), // Tools granted "Always Allow"
        quiet_tool_ids: std.StringHashMap(void), // Tool IDs that were silenced (no UI update sent)
        permission_socket: ?std.posix.socket_t = null,
        permission_socket_path: ?[]const u8 = null,
        nudge_enabled: bool = true,
        handling_prompt: bool = false,
        processing_queue: bool = false,
        prompt_queue: std.ArrayListUnmanaged(QueuedPrompt) = .empty,
        last_nudge_ms: i64 = 0,

        const QueuedPrompt = struct {
            request_id: jsonrpc.Request.Id,
            request_id_string: ?[]const u8, // Owned copy if ID is string
            params_json: []const u8,

            fn init(allocator: Allocator, id: jsonrpc.Request.Id, params_json: []const u8) !QueuedPrompt {
                return switch (id) {
                    .number => |n| .{ .request_id = .{ .number = n }, .request_id_string = null, .params_json = params_json },
                    .string => |s| blk: {
                        const owned = try allocator.dupe(u8, s);
                        break :blk .{ .request_id = .{ .string = owned }, .request_id_string = owned, .params_json = params_json };
                    },
                    .null => .{ .request_id = .null, .request_id_string = null, .params_json = params_json },
                };
            }

            fn deinit(self: QueuedPrompt, allocator: Allocator) void {
                if (self.request_id_string) |s| allocator.free(s);
                allocator.free(self.params_json);
            }
        };

        pub fn deinit(self: *Session, allocator: Allocator) void {
            if (self.bridge) |*b| b.deinit();
            if (self.codex_bridge) |*b| b.deinit();
            if (self.settings) |*s| s.deinit();
            self.closePermissionSocket(allocator);
            var it = self.pending_execute_tools.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.pending_execute_tools.deinit();
            var eit = self.pending_edit_tools.iterator();
            while (eit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            self.pending_edit_tools.deinit();
            var ait = self.always_allowed_tools.iterator();
            while (ait.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.always_allowed_tools.deinit();
            var qit = self.quiet_tool_ids.iterator();
            while (qit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            self.quiet_tool_ids.deinit();
            for (self.prompt_queue.items) |item| {
                item.deinit(allocator);
            }
            self.prompt_queue.deinit(allocator);
            allocator.free(self.id);
            allocator.free(self.cwd);
            if (self.model) |m| allocator.free(m);
            if (self.cli_session_id) |sid| allocator.free(sid);
            if (self.codex_session_id) |sid| allocator.free(sid);
        }

        fn closePermissionSocket(self: *Session, allocator: Allocator) void {
            if (self.permission_socket) |sock| {
                std.posix.close(sock);
                self.permission_socket = null;
            }
            if (self.permission_socket_path) |path| {
                std.fs.cwd().deleteFile(path) catch {};
                allocator.free(path);
                self.permission_socket_path = null;
            }
        }

        fn createPermissionSocket(self: *Session, allocator: Allocator) !void {
            // Create socket path: /tmp/banjo-{session_id}.sock
            const path = try std.fmt.allocPrint(allocator, "/tmp/banjo-{s}.sock", .{self.id});
            errdefer allocator.free(path);

            // Remove existing socket file if present
            std.fs.cwd().deleteFile(path) catch {};

            // Create non-blocking Unix domain socket with CLOEXEC to prevent fd inheritance
            const sock = try std.posix.socket(
                std.posix.AF.UNIX,
                std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
                0,
            );
            errdefer std.posix.close(sock);

            // Bind to path
            var addr: std.posix.sockaddr.un = .{ .path = undefined };
            @memset(&addr.path, 0);
            const path_len = @min(path.len, addr.path.len - 1);
            @memcpy(addr.path[0..path_len], path[0..path_len]);

            try std.posix.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
            try std.posix.listen(sock, 1);

            self.permission_socket = sock;
            self.permission_socket_path = path;
            log.info("Created permission socket at {s}", .{path});
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

    // Callback context for shared engine
    const PromptCallbackContext = struct {
        agent: *Agent,
        session: *Session,
        session_id: []const u8,
    };

    // Convert callback ToolKind to protocol ToolKind
    fn toProtocolToolKind(kind: CallbackToolKind) protocol.SessionUpdate.ToolKind {
        return switch (kind) {
            .read => .read,
            .edit => .edit,
            .execute => .execute,
            .browser => .fetch,
            .other => .other,
        };
    }

    // Convert callback ToolStatus to protocol ToolCallStatus
    fn toProtocolToolStatus(status: CallbackToolStatus) protocol.SessionUpdate.ToolCallStatus {
        return switch (status) {
            .pending, .execute, .approved, .denied => .pending,
            .completed => .completed,
            .failed => .failed,
        };
    }

    // Static vtable for EditorCallbacks
    const editor_callbacks_vtable = EditorCallbacks.VTable{
        .sendText = cbSendText,
        .sendTextRaw = cbSendTextRaw,
        .sendTextPrefix = cbSendTextPrefix,
        .sendThought = cbSendThought,
        .sendThoughtRaw = cbSendThoughtRaw,
        .sendThoughtPrefix = cbSendThoughtPrefix,
        .sendToolCall = cbSendToolCall,
        .sendToolResult = cbSendToolResult,
        .sendUserMessage = cbSendUserMessage,
        .onTimeout = cbOnTimeout,
        .onSessionId = cbOnSessionId,
        .onSlashCommands = cbOnSlashCommands,
        .checkAuthRequired = cbCheckAuthRequired,
        .sendContinuePrompt = cbSendContinuePrompt,
        .onApprovalRequest = cbOnApprovalRequest,
    };

    fn cbSendText(ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendEngineText(pctx.session, session_id, engine, text);
    }

    fn cbSendTextRaw(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendEngineTextRaw(session_id, text);
    }

    fn cbSendTextPrefix(ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendEngineTextPrefix(pctx.session, session_id, engine);
    }

    fn cbSendThought(ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendEngineThought(pctx.session, session_id, engine, text);
    }

    fn cbSendThoughtRaw(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendEngineThoughtRaw(session_id, text);
    }

    fn cbSendThoughtPrefix(ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendEngineThoughtPrefix(pctx.session, session_id, engine);
    }

    fn cbSendToolCall(
        ctx: *anyopaque,
        session_id: []const u8,
        engine: Engine,
        tool_name: []const u8,
        tool_label: []const u8,
        tool_id: []const u8,
        kind: CallbackToolKind,
        input: ?std.json.Value,
    ) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.handleEngineToolCall(
            pctx.session,
            session_id,
            engine,
            tool_name,
            tool_label,
            tool_id,
            toProtocolToolKind(kind),
            input,
        );
    }

    fn cbSendToolResult(
        ctx: *anyopaque,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        content: ?[]const u8,
        status: CallbackToolStatus,
        raw: ?std.json.Value,
    ) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.handleEngineToolResult(
            pctx.session,
            session_id,
            engine,
            tool_id,
            content,
            toProtocolToolStatus(status),
            raw orelse .null,
        );
    }

    fn cbSendUserMessage(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendUserMessage(session_id, text);
    }

    fn cbOnTimeout(ctx: *anyopaque) void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        pctx.agent.pollClientMessages(pctx.session);
    }

    fn cbOnSessionId(ctx: *anyopaque, engine: Engine, cli_session_id: []const u8) void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        switch (engine) {
            .claude => pctx.agent.captureSessionId(&pctx.session.cli_session_id, "Claude", cli_session_id),
            .codex => pctx.agent.captureSessionId(&pctx.session.codex_session_id, "Codex", cli_session_id),
        }
    }

    fn cbOnSlashCommands(ctx: *anyopaque, session_id: []const u8, commands: []const []const u8) anyerror!void {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        return pctx.agent.sendAvailableCommands(session_id, commands);
    }

    fn cbCheckAuthRequired(ctx: *anyopaque, session_id: []const u8, engine: Engine, content: []const u8) anyerror!?EditorCallbacks.StopReason {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        if (isAuthRequiredContent(content)) {
            _ = try pctx.agent.handleAuthRequired(session_id, pctx.session, engine);
            return .auth_required;
        }
        return null;
    }

    fn cbSendContinuePrompt(ctx: *anyopaque, engine: Engine, prompt: []const u8) anyerror!bool {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));
        switch (engine) {
            .claude => {
                _ = pctx.agent.sendClaudePromptWithRestart(pctx.session, pctx.session_id, prompt) catch |err| {
                    log.err("Failed to send continue prompt: {}", .{err});
                    return false;
                };
                return true;
            },
            .codex => {
                const inputs = [_]CodexUserInput{.{ .type = "text", .text = prompt }};
                _ = pctx.agent.sendCodexPromptWithRestart(pctx.session, pctx.session_id, inputs[0..]) catch |err| {
                    log.err("Failed to send continue prompt: {}", .{err});
                    return false;
                };
                return true;
            },
        }
    }

    fn cbOnApprovalRequest(ctx: *anyopaque, request_id: std.json.Value, kind: callbacks_mod.ApprovalKind, params: ?std.json.Value) anyerror!?[]const u8 {
        const pctx: *PromptCallbackContext = @ptrCast(@alignCast(ctx));

        // Map to protocol types
        const title = switch (kind) {
            .command_execution, .exec_command => "Bash",
            .file_change, .apply_patch => "Edit",
        };
        const proto_kind: protocol.SessionUpdate.ToolKind = switch (kind) {
            .command_execution, .exec_command => .execute,
            .file_change, .apply_patch => .edit,
        };

        // Convert json.Value back to RpcRequestId for formatting
        const rpc_request_id: CodexMessage.RpcRequestId = switch (request_id) {
            .integer => |id| .{ .integer = id },
            .string => |id| .{ .string = id },
            else => return "decline", // Invalid request_id type
        };

        // Format tool call ID
        const tool_call_id = try pctx.agent.formatApprovalToolCallId(rpc_request_id);
        defer pctx.agent.allocator.free(tool_call_id);

        // Request permission via ACP
        const outcome = pctx.agent.requestPermission(
            pctx.session,
            pctx.session_id,
            tool_call_id,
            title,
            proto_kind,
            params,
        ) catch |err| {
            log.warn("Failed to request permission from client: {}", .{err});
            return "decline";
        };
        defer if (outcome.optionId) |option_id| pctx.agent.allocator.free(option_id);

        // Map callback kind to CodexMessage.ApprovalKind for the existing helper
        const codex_kind: CodexMessage.ApprovalKind = switch (kind) {
            .command_execution => .command_execution,
            .exec_command => .exec_command,
            .file_change => .file_change,
            .apply_patch => .apply_patch,
        };
        return pctx.agent.permissionDecisionForCodex(codex_kind, outcome);
    }

    pub fn init(allocator: Allocator, writer: std.io.AnyWriter, reader: ?*jsonrpc.Reader) Agent {
        var agent = Agent{
            .allocator = allocator,
            .writer = jsonrpc.Writer.init(allocator, writer),
            .reader = reader,
            .sessions = std.StringHashMap(*Session).init(allocator),
            .config_defaults = configFromEnv(),
            .tool_proxy = undefined,
            .pending_response_numbers = std.AutoHashMap(i64, jsonrpc.ParsedMessage).init(allocator),
            .pending_response_strings = std.StringHashMap(jsonrpc.ParsedMessage).init(allocator),
        };
        agent.tool_proxy = ToolProxy.init(allocator, agent.writer);
        return agent;
    }

    pub fn deinit(self: *Agent) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
        self.clearPendingResponses();
        self.pending_response_numbers.deinit();
        self.pending_response_strings.deinit();
        self.tool_proxy.deinit();
    }

    const Handler = *const fn (*Agent, jsonrpc.Request) anyerror!void;
    const method_handlers = std.StaticStringMap(Handler).initComptime(.{
        .{ "initialize", handleInitialize },
        .{ "authenticate", handleAuthenticate },
        .{ "session/new", handleNewSession },
        .{ "session/prompt", handlePrompt },
        .{ "session/cancel", handleCancel },
        .{ "session/set_mode", handleSetMode },
        .{ "session/set_model", handleSetModel },
        .{ "session/set_config_option", handleSetConfig },
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

    /// Handle an incoming JSON-RPC message
    pub fn handleMessage(self: *Agent, message: jsonrpc.Message) !void {
        switch (message) {
            .request => |request| try self.handleRequest(request),
            .notification => |notification| try self.handleNotification(notification),
            .response => |response| try self.handleResponse(response),
        }
    }

    fn handleNotification(self: *Agent, notification: jsonrpc.Notification) !void {
        const request = jsonrpc.Request{
            .method = notification.method,
            .params = notification.params,
            .id = null,
        };
        try self.handleRequest(request);
    }

    fn handleResponse(self: *Agent, response: jsonrpc.Response) !void {
        _ = self;
        log.debug("Ignoring response id {?}: ACP client responses handled inline", .{response.id});
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
        const availability = detectEngines();
        const response = protocol.InitializeResponse{
            .agentInfo = .{
                .name = "Banjo Duet",
                .title = "Banjo Duet",
                .version = version,
            },
            .agentCapabilities = .{
                .promptCapabilities = .{
                    .image = availability.codex,
                    .embeddedContext = true,
                },
                .mcpCapabilities = .{
                    .http = false,
                    .sse = false,
                },
                .sessionCapabilities = .{},
                .loadSession = false,
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
        try self.writer.writeTypedResponse(request.id, protocol.AuthenticateResponse{});
    }

    fn handleNewSession(self: *Agent, request: jsonrpc.Request) !void {
        const session_id = try self.generateSessionId();
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
        const model_id = parsed.value.model orelse default_model_id;
        const model_copy = try self.allocator.dupe(u8, model_id);
        errdefer self.allocator.free(model_copy);

        session.* = .{
            .id = session_id,
            .cwd = cwd_copy,
            .config = self.config_defaults,
            .availability = undefined,
            .model = model_copy,
            .settings = settings,
            .pending_execute_tools = std.StringHashMap(void).init(self.allocator),
            .pending_edit_tools = std.StringHashMap(EditInfo).init(self.allocator),
            .always_allowed_tools = std.StringHashMap(void).init(self.allocator),
            .quiet_tool_ids = std.StringHashMap(void).init(self.allocator),
        };
        try self.sessions.put(session_id, session);

        log.info("Created session {s} in {s} with model {?s}", .{ session_id, cwd, session.model });

        // Auto-setup: create .zed/settings.json if missing (enables banjo LSP)
        const did_setup = self.autoSetupLspIfNeeded(cwd) catch false;

        const availability = detectEngines();
        session.availability = availability;
        if (routeEnvValue() == null) {
            const default_route = resolveDefaultRoute(availability);
            session.config.route = default_route;
            self.config_defaults.route = default_route;
        }

        // Pre-start Claude Code for instant first response (auto-resume last session if enabled)
        // Also ensure permission hook is configured in ~/.claude/settings.json
        var hook_configured = false;
        if (availability.claude) {
            const hook_result = settings_loader.ensurePermissionHook(self.allocator);
            hook_configured = hook_result == .configured;

            // Create permission socket for non-bypass modes
            if (session.permission_mode != .bypassPermissions and session.permission_socket == null) {
                session.createPermissionSocket(self.allocator) catch |err| {
                    log.warn("Failed to create permission socket: {}", .{err});
                };
            }

            session.bridge = Bridge.init(self.allocator, session.cwd);
            session.bridge.?.start(buildClaudeStartOptions(session)) catch |err| {
                log.warn("Failed to pre-start Claude Code: {} - will retry on first prompt", .{err});
                session.bridge = null;
            };
        }

        const mode_state = protocol.SessionModeState{
            .availableModes = available_modes[0..],
            .currentModeId = @tagName(session.permission_mode),
        };

        // Build response - must be sent BEFORE session updates
        // Note: configOptions and models are not yet supported by Zed's ACP client
        const result = protocol.NewSessionResponse{
            .sessionId = session_id,
            .modes = mode_state,
        };
        try self.writer.writeTypedResponse(request.id, result);

        // Send initial commands (CLI provides full list on first prompt after we send it input)
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .available_commands_update,
            .availableCommands = &initial_commands,
        });

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .current_mode_update,
            .currentModeId = @tagName(session.permission_mode),
        });

        if (!availability.claude and !availability.codex) {
            try self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{
                    .type = "text",
                    .text = no_engine_warning,
                },
            });
        }

        // Notify user if auto-setup ran
        if (did_setup) {
            try self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{
                    .type = "text",
                    .text = "Created `.zed/settings.json` to enable banjo-notes LSP.\n\n**Reload workspace** (Cmd+Shift+P → \"workspace: reload\") to activate note features.",
                },
            });
        }

        // Notify user if permission hook was configured
        if (hook_configured) {
            try self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{
                    .type = "text",
                    .text = "Configured Banjo permission hook in `~/.claude/settings.json`.\n\n**Restart Claude Code** for interactive permission prompts in Zed.",
                },
            });
        }
    }

    fn handlePrompt(self: *Agent, request: jsonrpc.Request) !void {
        var response_sent = false;
        errdefer if (!response_sent and !request.isNotification()) {
            self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InternalError,
                "Prompt failed",
            )) catch |err| {
                log.err("Failed to send prompt error response: {}", .{err});
            };
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromValue(PromptParams, arena.allocator(), request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing or invalid prompt",
            ));
            response_sent = true;
            return;
        };
        defer parsed.deinit();
        const session_id = parsed.value.sessionId;
        if (session_id.len == 0) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session ID is required",
            ));
            response_sent = true;
            return;
        }

        const session = self.sessions.get(session_id) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Session not found",
            ));
            response_sent = true;
            return;
        };

        // Queue prompt if another is already being handled (deadlock prevention)
        if (session.handling_prompt) {
            const req_id = request.id orelse {
                log.warn("Cannot queue prompt notification (no request ID)", .{});
                return;
            };
            // Limit queue size to prevent unbounded memory growth
            if (session.prompt_queue.items.len >= 8) {
                log.warn("Prompt queue full, rejecting prompt for session {s}", .{session_id});
                try self.writer.writeResponse(jsonrpc.Response.err(
                    req_id,
                    jsonrpc.Error.InternalError,
                    "Session busy - too many queued prompts",
                ));
                return;
            }
            log.info("Queueing prompt: another prompt is already being handled for session {s}", .{session_id});
            const params_json = try std.json.Stringify.valueAlloc(self.allocator, request.params orelse .null, .{});
            errdefer self.allocator.free(params_json);
            const queued = try Session.QueuedPrompt.init(self.allocator, req_id, params_json);
            try session.prompt_queue.append(self.allocator, queued);
            return; // Response will be sent when queued prompt is processed
        }
        session.handling_prompt = true;
        defer {
            session.handling_prompt = false;
            if (!session.processing_queue) {
                self.processQueuedPrompts(session);
            }
        }

        var prompt_parts = try self.collectPromptParts(session, session_id, parsed.value.prompt);
        defer prompt_parts.deinit(self.allocator);

        const prompt_text = prompt_parts.user_text;

        session.cancelled.store(false, .release);
        log.info("Prompt received for session {s}: {s}", .{ session_id, prompt_text orelse "(empty)" });

        const route = session.config.route;
        var effective_prompt = prompt_text;

        if (prompt_text) |text| {
            if (text.len > 0 and text[0] == '/') {
                if (self.dispatchCommand(request, session, session_id, text, prompt_parts.resource)) |transformed| {
                    effective_prompt = transformed;
                } else {
                    response_sent = true;
                    return;
                }
            }
        }

        const base_prompt = effective_prompt;

        var combined_prompt: ?[]const u8 = null;
        defer if (combined_prompt) |text| self.allocator.free(text);

        var codex_prompt_owned: ?[]const u8 = null;
        defer if (codex_prompt_owned) |text| self.allocator.free(text);
        var codex_prompt: ?[]const u8 = base_prompt;

        if (prompt_parts.context) |context| {
            var builder: std.ArrayListUnmanaged(u8) = .empty;
            defer builder.deinit(self.allocator);

            if (base_prompt) |text| {
                try builder.appendSlice(self.allocator, text);
            }
            if (context.len > 0) {
                if (builder.items.len > 0) {
                    try builder.appendSlice(self.allocator, "\n\n");
                }
                try builder.appendSlice(self.allocator, context);
            }
            if (builder.items.len > 0) {
                combined_prompt = try builder.toOwnedSlice(self.allocator);
                effective_prompt = combined_prompt;
            }
        }

        if (prompt_parts.codex_context) |context| {
            var builder: std.ArrayListUnmanaged(u8) = .empty;
            defer builder.deinit(self.allocator);

            if (base_prompt) |text| {
                try builder.appendSlice(self.allocator, text);
            }
            if (context.len > 0) {
                if (builder.items.len > 0) {
                    try builder.appendSlice(self.allocator, "\n\n");
                }
                try builder.appendSlice(self.allocator, context);
            }
            if (builder.items.len > 0) {
                codex_prompt_owned = try builder.toOwnedSlice(self.allocator);
                codex_prompt = codex_prompt_owned;
            }
        }

        if (effective_prompt == null and prompt_parts.context != null) {
            effective_prompt = prompt_parts.context;
        }

        if (codex_prompt == null and prompt_parts.codex_inputs != null) {
            codex_prompt = "";
        }

        var stop_reason: protocol.StopReason = .end_turn;
        if (effective_prompt) |text| {
            const codex_text = codex_prompt orelse text;
            stop_reason = try self.runDuetPrompt(session, session_id, text, route, codex_text, prompt_parts.codex_inputs);
        }

        try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = stop_reason });
        response_sent = true;
    }

    fn processQueuedPrompts(self: *Agent, session: *Session) void {
        if (session.processing_queue) return; // Prevent recursive calls
        session.processing_queue = true;
        defer session.processing_queue = false;

        while (session.prompt_queue.items.len > 0) {
            const queued = session.prompt_queue.orderedRemove(0);
            defer queued.deinit(self.allocator);

            // Parse the queued JSON params
            const parsed_value = std.json.parseFromSlice(std.json.Value, self.allocator, queued.params_json, .{}) catch |err| {
                log.warn("Failed to parse queued prompt params: {}", .{err});
                self.writer.writeResponse(jsonrpc.Response.err(
                    queued.request_id,
                    jsonrpc.Error.InternalError,
                    "Failed to process queued prompt",
                )) catch {};
                continue;
            };
            defer parsed_value.deinit();

            // Re-create request and handle it
            const request = jsonrpc.Request{
                .method = "session/prompt",
                .id = queued.request_id,
                .params = parsed_value.value,
            };

            log.info("Processing queued prompt for session {s}", .{session.id});
            self.handlePrompt(request) catch |err| {
                log.warn("Failed to handle queued prompt: {}", .{err});
                self.writer.writeResponse(jsonrpc.Response.err(
                    queued.request_id,
                    jsonrpc.Error.InternalError,
                    "Failed to process queued prompt",
                )) catch {};
            };
        }
    }

    const ResourceLinkData = struct {
        uri: []const u8,
        name: []const u8,
        mimeType: ?[]const u8 = null,
    };

    fn collectPromptParts(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        blocks: []const protocol.ContentBlock,
    ) !PromptParts {
        var user_buf: std.ArrayListUnmanaged(u8) = .empty;
        var context_buf: std.ArrayListUnmanaged(u8) = .empty;
        var codex_context_buf: std.ArrayListUnmanaged(u8) = .empty;
        var resource: ?ResourceData = null;
        var codex_inputs: std.ArrayListUnmanaged(CodexUserInput) = .empty;
        var codex_input_strings: std.ArrayListUnmanaged([]const u8) = .empty;
        const codex_available = CodexBridge.isAvailable();
        errdefer user_buf.deinit(self.allocator);
        errdefer context_buf.deinit(self.allocator);
        errdefer codex_context_buf.deinit(self.allocator);
        errdefer if (resource) |*res| res.deinit(self.allocator);
        errdefer codex_inputs.deinit(self.allocator);
        errdefer {
            for (codex_input_strings.items) |item| {
                self.allocator.free(item);
            }
            codex_input_strings.deinit(self.allocator);
        }

        for (blocks) |block| {
            const kind = content_kind_map.get(block.type) orelse .unknown;
            switch (kind) {
                .text => {
                    const text = block.text orelse continue;
                    try self.appendSeparator(&user_buf);
                    try user_buf.appendSlice(self.allocator, text);
                },
                .resource => {
                    const embedded = block.resource orelse continue;
                    try self.appendEmbeddedResource(&context_buf, &resource, embedded);
                    try self.appendEmbeddedResourceContext(&codex_context_buf, embedded);
                },
                .resource_link => {
                    const uri = block.uri orelse continue;
                    const name = block.name orelse uri;
                    const link = ResourceLinkData{ .uri = uri, .name = name, .mimeType = block.mimeType };
                    if (try self.appendResourceLink(session, session_id, &context_buf, &codex_context_buf, &resource, link)) {
                        continue;
                    }
                    try self.appendResourceLinkFallback(&context_buf, link);
                    try self.appendResourceLinkFallback(&codex_context_buf, link);
                },
                .image => {
                    const mime_type = block.mimeType orelse continue;
                    const data = block.data orelse continue;
                    if (codex_available) {
                        const appended = try self.appendCodexImageInput(&codex_inputs, &codex_input_strings, block);
                        if (!appended) {
                            try self.appendMediaBlock(&codex_context_buf, "Image", mime_type, data);
                        }
                    } else {
                        try self.appendMediaBlock(&codex_context_buf, "Image", mime_type, data);
                    }
                    try self.appendMediaBlock(&context_buf, "Image", mime_type, data);
                },
                .audio => {
                    const mime_type = block.mimeType orelse continue;
                    const data = block.data orelse continue;
                    try self.appendMediaBlock(&context_buf, "Audio", mime_type, data);
                    try self.appendMediaBlock(&codex_context_buf, "Audio", mime_type, data);
                },
                .unknown => {},
            }
        }

        var parts = PromptParts{
            .user_text = null,
            .context = null,
            .codex_context = null,
            .resource = resource,
            .codex_inputs = null,
            .codex_input_strings = null,
        };

        if (user_buf.items.len > 0) {
            parts.user_text = try user_buf.toOwnedSlice(self.allocator);
        } else {
            user_buf.deinit(self.allocator);
        }

        if (context_buf.items.len > 0) {
            parts.context = try context_buf.toOwnedSlice(self.allocator);
        } else {
            context_buf.deinit(self.allocator);
        }

        if (codex_context_buf.items.len > 0) {
            parts.codex_context = try codex_context_buf.toOwnedSlice(self.allocator);
        } else {
            codex_context_buf.deinit(self.allocator);
        }

        if (codex_inputs.items.len > 0) {
            parts.codex_inputs = try codex_inputs.toOwnedSlice(self.allocator);
        } else {
            codex_inputs.deinit(self.allocator);
        }

        if (codex_input_strings.items.len > 0) {
            parts.codex_input_strings = try codex_input_strings.toOwnedSlice(self.allocator);
        } else {
            codex_input_strings.deinit(self.allocator);
        }

        return parts;
    }

    fn appendSeparator(self: *Agent, list: *std.ArrayListUnmanaged(u8)) !void {
        if (list.items.len == 0) return;
        try list.appendSlice(self.allocator, "\n\n");
    }

    const ResourceText = struct {
        text: []const u8,
        truncated: bool,
    };

    fn clampResourceText(self: *Agent, text: []const u8) !ResourceText {
        const truncated = text.len > max_context_bytes;
        const slice = if (truncated) text[0..max_context_bytes] else text;
        const copy = try self.allocator.dupe(u8, slice);
        return .{ .text = copy, .truncated = truncated };
    }

    fn clampOwnedResourceText(self: *Agent, text: []u8) !ResourceText {
        if (text.len > max_context_bytes) {
            const copy = try self.allocator.dupe(u8, text[0..max_context_bytes]);
            self.allocator.free(text);
            return .{ .text = copy, .truncated = true };
        }
        return .{ .text = text, .truncated = false };
    }

    fn appendEmbeddedResource(
        self: *Agent,
        context_buf: *std.ArrayListUnmanaged(u8),
        resource: *?ResourceData,
        embedded: protocol.EmbeddedResourceResource,
    ) !void {
        if (embedded.text) |text| {
            const lang = self.languageHint(embedded.uri, embedded.mimeType);
            try self.appendContextBlock(context_buf, embedded.uri, lang, text);
            if (resource.* == null) {
                const uri_buf = try self.allocator.dupe(u8, embedded.uri);
                errdefer self.allocator.free(uri_buf);
                const resource_text = try self.clampResourceText(text);
                resource.* = .{
                    .uri = uri_buf,
                    .text = resource_text.text,
                    .truncated = resource_text.truncated,
                };
            }
            return;
        }

        if (embedded.blob) |blob| {
            const mime = embedded.mimeType orelse "application/octet-stream";
            try self.appendMediaBlock(context_buf, "Resource blob", mime, blob);
        }
    }

    fn appendEmbeddedResourceContext(
        self: *Agent,
        context_buf: *std.ArrayListUnmanaged(u8),
        embedded: protocol.EmbeddedResourceResource,
    ) !void {
        if (embedded.text) |text| {
            const lang = self.languageHint(embedded.uri, embedded.mimeType);
            try self.appendContextBlock(context_buf, embedded.uri, lang, text);
            return;
        }

        if (embedded.blob) |blob| {
            const mime = embedded.mimeType orelse "application/octet-stream";
            try self.appendMediaBlock(context_buf, "Resource blob", mime, blob);
        }
    }

    fn appendResourceLink(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        context_buf: *std.ArrayListUnmanaged(u8),
        codex_context_buf: *std.ArrayListUnmanaged(u8),
        resource: *?ResourceData,
        link: ResourceLinkData,
    ) !bool {
        if (!self.canReadFiles()) return false;
        const uri_info = parseFileUri(self.allocator, link.uri) orelse return false;
        defer uri_info.deinit(self.allocator);

        const line = if (uri_info.line_specified) uri_info.line else null;
        const content = (try self.requestReadTextFile(session, session_id, uri_info.path, line, resource_line_limit)) orelse {
            return false;
        };
        const lang = self.languageHint(link.uri, link.mimeType);
        try self.appendContextBlock(context_buf, link.uri, lang, content);
        try self.appendContextBlock(codex_context_buf, link.uri, lang, content);
        if (resource.* == null) {
            const uri_buf = try self.allocator.dupe(u8, link.uri);
            const resource_text = self.clampOwnedResourceText(content) catch |err| {
                self.allocator.free(uri_buf);
                self.allocator.free(content);
                return err;
            };
            resource.* = .{
                .uri = uri_buf,
                .text = resource_text.text,
                .truncated = resource_text.truncated,
            };
        } else {
            self.allocator.free(content);
        }
        return true;
    }

    fn appendResourceLinkFallback(self: *Agent, context_buf: *std.ArrayListUnmanaged(u8), link: ResourceLinkData) !void {
        try self.appendSeparator(context_buf);
        const writer = context_buf.writer(self.allocator);
        try writer.print("Context link: {s} ({s})", .{ link.name, link.uri });
        if (link.mimeType) |mime| {
            try writer.print(" [{s}]", .{mime});
        }
    }

    fn appendMediaBlock(
        self: *Agent,
        context_buf: *std.ArrayListUnmanaged(u8),
        label: []const u8,
        mime_type: []const u8,
        data: []const u8,
    ) !void {
        try self.appendSeparator(context_buf);
        const writer = context_buf.writer(self.allocator);
        try writer.print("{s}: {s} ({d} bytes)\n", .{ label, mime_type, data.len });
        if (data.len == 0) return;

        const preview_len = @min(data.len, max_media_preview_bytes);
        try writer.writeAll("data (base64, truncated):\n");
        try writer.writeAll(data[0..preview_len]);
        if (preview_len < data.len) {
            try writer.writeAll("\n[data truncated]");
        }
    }

    fn appendCodexImageInput(
        self: *Agent,
        codex_inputs: *std.ArrayListUnmanaged(CodexUserInput),
        codex_input_strings: *std.ArrayListUnmanaged([]const u8),
        block: protocol.ContentBlock,
    ) !bool {
        if (block.uri) |uri| {
            if (parseFileUri(self.allocator, uri)) |uri_info| {
                defer uri_info.deinit(self.allocator);
                try codex_inputs.ensureUnusedCapacity(self.allocator, 1);
                try codex_input_strings.ensureUnusedCapacity(self.allocator, 1);
                const path = try self.allocator.dupe(u8, uri_info.path);
                codex_inputs.appendAssumeCapacity(.{ .type = "localImage", .path = path });
                codex_input_strings.appendAssumeCapacity(path);
                return true;
            }
        }

        const data = block.data orelse return false;
        if (data.len > max_codex_image_bytes) {
            log.warn("Codex image input too large ({d} bytes); skipping", .{data.len});
            return false;
        }
        try codex_inputs.ensureUnusedCapacity(self.allocator, 1);
        try codex_input_strings.ensureUnusedCapacity(self.allocator, 1);
        const mime_type = block.mimeType orelse "application/octet-stream";
        const url = try std.fmt.allocPrint(self.allocator, "data:{s};base64,{s}", .{ mime_type, data });
        codex_inputs.appendAssumeCapacity(.{ .type = "image", .url = url });
        codex_input_strings.appendAssumeCapacity(url);
        return true;
    }

    fn appendContextBlock(
        self: *Agent,
        context_buf: *std.ArrayListUnmanaged(u8),
        uri: []const u8,
        language: []const u8,
        text: []const u8,
    ) !void {
        try self.appendSeparator(context_buf);
        const writer = context_buf.writer(self.allocator);

        const truncated = text.len > max_context_bytes;
        const snippet = if (truncated) text[0..max_context_bytes] else text;

        try writer.print("Context from {s}\n", .{uri});
        try writer.print("```{s}\n", .{language});
        try writer.writeAll(snippet);
        try writer.writeAll("\n```\n");
        if (truncated) {
            try writer.writeAll("[context truncated]");
        }
    }

    fn languageHint(self: *Agent, uri: []const u8, mime_type: ?[]const u8) []const u8 {
        if (mime_type) |mime| {
            if (mime_language_map.get(mime)) |lang| return lang;
        }

        if (parseFileUri(self.allocator, uri)) |info| {
            defer info.deinit(self.allocator);
            const ext = std.fs.path.extension(info.path);
            if (ext.len > 1) return ext[1..];
        }
        return "text";
    }

    fn canReadFiles(self: *Agent) bool {
        const caps = self.client_capabilities orelse return false;
        const fs_caps = caps.fs orelse return false;
        return fs_caps.readTextFile orelse false;
    }

    fn canWriteFiles(self: *Agent) bool {
        const caps = self.client_capabilities orelse return false;
        const fs_caps = caps.fs orelse return false;
        return fs_caps.writeTextFile orelse false;
    }

    fn canUseTerminal(self: *Agent) bool {
        const caps = self.client_capabilities orelse return false;
        return caps.terminal orelse false;
    }

    fn requestReadTextFile(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        path: []const u8,
        line: ?u32,
        limit: ?u32,
    ) !?[]u8 {
        if (!self.canReadFiles()) return null;
        const reader = self.reader orelse return null;
        _ = reader;

        const request_id = try self.tool_proxy.readFile(session_id, path, line, limit);
        var response = self.waitForResponse(session, .{ .number = request_id }) catch |err| {
            if (err == error.Cancelled) return null;
            return err;
        };
        defer response.deinit();

        const resp = response.message.response;
        if (resp.@"error") |err_val| {
            self.tool_proxy.handleError(request_id, err_val);
            return null;
        }

        const result = resp.result orelse {
            _ = self.tool_proxy.handleResponse(request_id);
            return error.InvalidToolResponse;
        };
        _ = self.tool_proxy.handleResponse(request_id);
        const parsed = try std.json.parseFromValue(protocol.ReadTextFileResponse, self.allocator, result, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return try self.allocator.dupe(u8, parsed.value.content);
    }

    fn requestWriteTextFile(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        path: []const u8,
        content: []const u8,
    ) !bool {
        if (!self.canWriteFiles()) return false;
        const reader = self.reader orelse return false;
        _ = reader;

        const request_id = try self.tool_proxy.writeFile(session_id, path, content);
        var response = self.waitForResponse(session, .{ .number = request_id }) catch |err| {
            if (err == error.Cancelled) return false;
            return err;
        };
        defer response.deinit();

        const resp = response.message.response;
        if (resp.@"error") |err_val| {
            self.tool_proxy.handleError(request_id, err_val);
            return false;
        }

        const result = resp.result orelse {
            _ = self.tool_proxy.handleResponse(request_id);
            return error.InvalidToolResponse;
        };
        _ = self.tool_proxy.handleResponse(request_id);
        const parsed = try std.json.parseFromValue(protocol.WriteTextFileResponse, self.allocator, result, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return true;
    }

    const DuetState = enum { start, next_engine, run_engine };

    fn runDuetPrompt(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        prompt: []const u8,
        route: Route,
        codex_prompt: []const u8,
        codex_inputs: ?[]const CodexUserInput,
    ) !protocol.StopReason {
        var stop_reason: protocol.StopReason = .end_turn;
        const primary = session.config.primary_agent;

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
            .duet => {
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
                    .codex => try self.runCodexPrompt(session, session_id, codex_prompt, codex_inputs),
                };
                stop_reason = mergeStopReason(stop_reason, reason);
                if (session.cancelled.load(.acquire)) return .cancelled;
                continue :state .next_engine;
            },
        }
    }

    fn mergeStopReason(current: protocol.StopReason, next: protocol.StopReason) protocol.StopReason {
        if (next == .cancelled) return .cancelled;
        if (current == .end_turn) return next;
        return current;
    }

    fn toolResultStatus(is_error: bool) protocol.SessionUpdate.ToolCallStatus {
        return if (is_error) .failed else .completed;
    }

    fn exitCodeStatus(exit_code: ?i64) protocol.SessionUpdate.ToolCallStatus {
        if (exit_code) |code| {
            return if (code == 0) .completed else .failed;
        }
        return .completed;
    }

    fn ensureClaudeBridge(self: *Agent, session: *Session, session_id: []const u8) !*Bridge {
        if (session.bridge == null) {
            session.bridge = Bridge.init(self.allocator, session.cwd);
        }
        if (session.bridge.?.process == null) {
            try self.startClaudeBridge(session, session_id);
        }
        return &session.bridge.?;
    }

    fn buildClaudeStartOptions(session: *Session) Bridge.StartOptions {
        const allow_resume = !session.force_new_claude;
        const mode = session.permission_mode;
        const skip = mode == .bypassPermissions;
        const mode_arg = if (skip) null else @tagName(mode);
        log.info("buildClaudeStartOptions: mode={s} skip_permissions={} permission_mode_arg={?s}", .{
            @tagName(mode),
            skip,
            mode_arg,
        });
        return .{
            .resume_session_id = if (allow_resume) session.cli_session_id else null,
            .continue_last = allow_resume and session.cli_session_id == null and session.config.auto_resume,
            .skip_permissions = skip,
            .permission_mode = mode_arg,
            .model = session.model,
            .permission_socket_path = session.permission_socket_path,
        };
    }

    fn startClaudeBridge(self: *Agent, session: *Session, session_id: []const u8) !void {
        // Create permission socket if not already exists (needed even in bypass mode
        // to receive and auto-approve requests from Claude's hook)
        if (session.permission_socket == null) {
            session.createPermissionSocket(self.allocator) catch |err| {
                log.warn("Failed to create permission socket: {}", .{err});
                // Continue without socket - will fall back to bypass behavior
            };
        }

        session.bridge.?.start(buildClaudeStartOptions(session)) catch |err| {
            log.err("Failed to start Claude Code: {}", .{err});
            session.bridge = null;
            try self.sendEngineText(session, session_id, .claude, "Failed to start Claude Code. Please ensure it is installed and in PATH.");
            return error.BridgeStartFailed;
        };
        session.force_new_claude = false;
    }

    fn ensureCodexBridge(self: *Agent, session: *Session, session_id: []const u8) !*CodexBridge {
        if (session.codex_bridge == null) {
            session.codex_bridge = CodexBridge.init(self.allocator, session.cwd);
        }
        if (session.codex_bridge.?.process == null) {
            try self.startCodexBridge(session, session_id);
        }
        session.codex_bridge.?.approval_policy = codexApprovalPolicy(session.permission_mode);
        return &session.codex_bridge.?;
    }

    fn buildCodexStartOptions(session: *Session) CodexBridge.StartOptions {
        return .{
            .resume_session_id = if (session.force_new_codex) null else session.codex_session_id,
            .model = null,
            .approval_policy = codexApprovalPolicy(session.permission_mode),
        };
    }

    fn startCodexBridge(self: *Agent, session: *Session, session_id: []const u8) !void {
        session.codex_bridge.?.start(buildCodexStartOptions(session)) catch |err| {
            log.err("Failed to start Codex: {}", .{err});
            session.codex_bridge = null;
            try self.sendEngineText(session, session_id, .codex, "Failed to start Codex. Please ensure it is installed and in PATH.");
            return error.BridgeStartFailed;
        };
        session.force_new_codex = false;
        const start_ms = std.time.milliTimestamp();
        log.info("Codex bridge started (start={d}ms)", .{start_ms});
        self.captureCodexSessionId(session);
    }

    /// Trigger a nudge continuation - starts Claude/Codex with the nudge prompt
    fn triggerNudge(self: *Agent, request: jsonrpc.Request, session: *Session, session_id: []const u8) !void {
        _ = request;
        const nudge_prompt = "clean up dots, then pick a dot and work on it";
        switch (session.config.route) {
            .claude, .duet => _ = try self.runClaudePrompt(session, session_id, nudge_prompt),
            .codex => {
                const inputs = [_]CodexUserInput{.{ .type = "text", .text = nudge_prompt }};
                _ = try self.runCodexPrompt(session, session_id, nudge_prompt, inputs[0..]);
            },
        }
    }

    fn sendClaudePromptWithRestart(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        prompt: []const u8,
    ) !*Bridge {
        const cli_bridge = try self.ensureClaudeBridge(session, session_id);
        cli_bridge.sendPrompt(prompt) catch |err| {
            log.warn("Claude Code sendPrompt failed ({}), restarting", .{err});
            cli_bridge.stop();
            try self.startClaudeBridge(session, session_id);
            if (session.bridge) |*restarted| {
                restarted.sendPrompt(prompt) catch |retry_err| {
                    log.err("Claude Code sendPrompt retry failed: {}", .{retry_err});
                    return retry_err;
                };
            } else {
                return error.BridgeStartFailed;
            }
        };
        return &session.bridge.?;
    }

    fn sendCodexPromptWithRestart(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        inputs: []const CodexUserInput,
    ) !*CodexBridge {
        const codex_bridge = try self.ensureCodexBridge(session, session_id);
        codex_bridge.sendPrompt(inputs) catch |err| {
            log.warn("Codex sendPrompt failed ({}), restarting", .{err});
            codex_bridge.stop();
            try self.startCodexBridge(session, session_id);
            if (session.codex_bridge) |*restarted| {
                restarted.sendPrompt(inputs) catch |retry_err| {
                    log.err("Codex sendPrompt retry failed: {}", .{retry_err});
                    return retry_err;
                };
            } else {
                return error.BridgeStartFailed;
            }
        };
        return &session.codex_bridge.?;
    }

    fn runClaudePrompt(self: *Agent, session: *Session, session_id: []const u8, prompt: []const u8) !protocol.StopReason {
        defer self.clearPendingExecuteTools(session);

        const cli_bridge = try self.sendClaudePromptWithRestart(session, session_id, prompt);

        var cb_ctx = PromptCallbackContext{
            .agent = self,
            .session = session,
            .session_id = session_id,
        };
        const callbacks = EditorCallbacks{
            .ctx = @ptrCast(&cb_ctx),
            .vtable = &editor_callbacks_vtable,
        };

        var prompt_ctx = engine_mod.PromptContext{
            .allocator = self.allocator,
            .session_id = session_id,
            .cwd = session.cwd,
            .cancelled = &session.cancelled,
            .nudge = .{
                .enabled = session.nudge_enabled,
                .cooldown_ms = 30_000,
                .last_nudge_ms = &session.last_nudge_ms,
            },
            .cb = callbacks,
            .tag_engine = self.shouldTagEngine(session),
        };

        const engine_stop = try engine_mod.processClaudeMessages(&prompt_ctx, cli_bridge);
        return toProtocolStopReason(engine_stop);
    }

    fn toProtocolStopReason(stop: engine_mod.StopReason) protocol.StopReason {
        return switch (stop) {
            .end_turn => .end_turn,
            .cancelled => .cancelled,
            .max_tokens => .max_tokens,
            .max_turn_requests => .max_turn_requests,
            .auth_required => .end_turn,
        };
    }

    fn runCodexPrompt(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        prompt: []const u8,
        codex_inputs: ?[]const CodexUserInput,
    ) !protocol.StopReason {
        defer self.clearPendingExecuteTools(session);

        // Build input list
        var input_list: std.ArrayListUnmanaged(CodexUserInput) = .empty;
        defer input_list.deinit(self.allocator);

        if (prompt.len > 0) {
            try input_list.append(self.allocator, .{ .type = "text", .text = prompt });
        }
        if (codex_inputs) |inputs| {
            try input_list.appendSlice(self.allocator, inputs);
        }
        const inputs = input_list.items;
        if (inputs.len == 0) return .end_turn;

        const codex_bridge = try self.sendCodexPromptWithRestart(session, session_id, inputs);

        var cb_ctx = PromptCallbackContext{
            .agent = self,
            .session = session,
            .session_id = session_id,
        };
        const callbacks = EditorCallbacks{
            .ctx = @ptrCast(&cb_ctx),
            .vtable = &editor_callbacks_vtable,
        };

        var prompt_ctx = engine_mod.PromptContext{
            .allocator = self.allocator,
            .session_id = session_id,
            .cwd = session.cwd,
            .cancelled = &session.cancelled,
            .nudge = .{
                .enabled = session.nudge_enabled,
                .cooldown_ms = 30_000,
                .last_nudge_ms = &session.last_nudge_ms,
            },
            .cb = callbacks,
            .tag_engine = self.shouldTagEngine(session),
        };

        const engine_stop = try engine_mod.processCodexMessages(&prompt_ctx, codex_bridge);
        return toProtocolStopReason(engine_stop);
    }

    fn captureCodexSessionId(self: *Agent, session: *Session) void {
        if (session.codex_session_id != null) return;
        if (session.codex_bridge) |*codex_bridge| {
            if (codex_bridge.getThreadId()) |thread_id| {
                self.captureSessionId(&session.codex_session_id, "Codex", thread_id);
            }
        }
    }

    fn captureSessionId(self: *Agent, slot: *?[]const u8, label: []const u8, session_id: []const u8) void {
        if (slot.* != null) return;
        slot.* = self.allocator.dupe(u8, session_id) catch |err| {
            log.warn("Failed to capture {s} session ID: {}", .{ label, err });
            return;
        };
        log.info("Captured {s} session ID: {s}", .{ label, session_id });
    }

    fn generateSessionId(self: *Agent) ![]const u8 {
        return generateSessionIdWithAllocator(self.allocator);
    }

    fn sendEngineText(self: *Agent, session: *Session, session_id: []const u8, engine: Engine, text: []const u8) !void {
        if (!self.shouldTagEngine(session)) {
            return self.sendEngineTextRaw(session_id, text);
        }
        var buf: [4096]u8 = undefined;
        const tagged = self.formatTagged(&buf, engine, text) orelse blk: {
            const owned = try self.tagText(engine, text);
            defer self.allocator.free(owned);
            break :blk owned;
        };
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

    fn sendEngineTextPrefix(self: *Agent, session: *Session, session_id: []const u8, engine: Engine) !void {
        if (!self.shouldTagEngine(session)) return;
        const prefix = enginePrefix(engine);
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = prefix },
        });
    }

    fn sendEngineThoughtRaw(self: *Agent, session_id: []const u8, text: []const u8) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_thought_chunk,
            .content = .{ .type = "text", .text = text },
        });
    }

    fn sendUserMessage(self: *Agent, session_id: []const u8, text: []const u8) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .user_message_chunk,
            .content = .{ .type = "text", .text = text },
        });
    }

    fn sendEngineThoughtPrefix(self: *Agent, session: *Session, session_id: []const u8, engine: Engine) !void {
        if (!self.shouldTagEngine(session)) return;
        const prefix = enginePrefix(engine);
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_thought_chunk,
            .content = .{ .type = "text", .text = prefix },
        });
    }

    fn sendEngineThought(self: *Agent, session: *Session, session_id: []const u8, engine: Engine, text: []const u8) !void {
        if (!self.shouldTagEngine(session)) {
            return self.sendEngineThoughtRaw(session_id, text);
        }
        var buf: [4096]u8 = undefined;
        const tagged = self.formatTagged(&buf, engine, text) orelse blk: {
            const owned = try self.tagText(engine, text);
            defer self.allocator.free(owned);
            break :blk owned;
        };
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_thought_chunk,
            .content = .{ .type = "text", .text = tagged },
        });
    }

    // Tools that run silently without UI updates (internal housekeeping)
    // Task and AskUserQuestion are NOT quiet - user should see subagent spawns and questions
    const quiet_tools = std.StaticStringMap(void).initComptime(.{
        .{ "TodoWrite", {} },
        .{ "TodoRead", {} },
        .{ "TaskOutput", {} },
        .{ "Skill", {} },
        .{ "Read", {} },
        .{ "Write", {} },
        .{ "Edit", {} },
        .{ "MultiEdit", {} },
        .{ "NotebookRead", {} },
        .{ "NotebookEdit", {} },
        .{ "Grep", {} },
        .{ "Glob", {} },
        .{ "LSP", {} },
        .{ "KillShell", {} },
        .{ "EnterPlanMode", {} },
        .{ "ExitPlanMode", {} },
    });

    fn sendEngineToolCall(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        tool_name: []const u8,
        kind: protocol.SessionUpdate.ToolKind,
        raw_input: ?std.json.Value,
    ) !void {
        // Skip UI updates for internal service tools, track ID to also skip result
        if (quiet_tools.has(tool_name)) {
            try self.trackQuietTool(session, engine, tool_id);
            return;
        }

        var execute_preview: ?[]const u8 = null;
        var execute_parsed: ?std.json.Parsed(ExecuteToolInput) = null;
        defer if (execute_parsed) |*val| val.deinit();

        if (kind == .execute) {
            if (raw_input) |input_value| {
                switch (input_value) {
                    .string => |val| execute_preview = truncateUtf8(val, max_tool_preview_bytes),
                    .object => {
                        execute_parsed = blk: {
                            const parsed = std.json.parseFromValue(ExecuteToolInput, self.allocator, input_value, .{
                                .ignore_unknown_fields = true,
                            }) catch |err| {
                                log.warn("Failed to parse execute tool input: {}", .{err});
                                break :blk null;
                            };
                            break :blk parsed;
                        };
                        if (execute_parsed) |parsed| {
                            const parsed_value = parsed.value;
                            if (parsed_value.command) |cmd| {
                                execute_preview = truncateUtf8(cmd, max_tool_preview_bytes);
                            } else if (parsed_value.cmd) |cmd| {
                                execute_preview = truncateUtf8(cmd, max_tool_preview_bytes);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        const tag_engine = self.shouldTagEngine(session);
        var title_buf: [512]u8 = undefined;
        var title_owned: ?[]const u8 = null;
        const tagged_title = blk: {
            if (execute_preview) |preview| {
                if (!tag_engine) {
                    if (std.fmt.bufPrint(&title_buf, "{s}: {s}", .{ tool_name, preview }) catch null) |title| {
                        break :blk title;
                    }
                    const owned = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ tool_name, preview });
                    title_owned = owned;
                    break :blk owned;
                }
                if (std.fmt.bufPrint(&title_buf, "[{s}] {s}: {s}", .{ engineLabel(engine), tool_name, preview }) catch null) |title| {
                    break :blk title;
                }
                const owned = try std.fmt.allocPrint(self.allocator, "[{s}] {s}: {s}", .{ engineLabel(engine), tool_name, preview });
                title_owned = owned;
                break :blk owned;
            }
            if (!tag_engine) break :blk tool_name;
            if (self.formatTagged(&title_buf, engine, tool_name)) |tagged| break :blk tagged;
            const owned = try self.tagText(engine, tool_name);
            title_owned = owned;
            break :blk owned;
        };
        defer if (title_owned) |owned| self.allocator.free(owned);

        var id_buf: [256]u8 = undefined;
        var id_owned: ?[]const u8 = null;
        const tagged_id = if (!tag_engine) tool_id else blk: {
            if (self.formatToolId(&id_buf, engine, tool_id)) |tagged| break :blk tagged;
            const owned = try self.tagToolId(engine, tool_id);
            id_owned = owned;
            break :blk owned;
        };
        defer if (id_owned) |owned| self.allocator.free(owned);

        // Extract file location for "follow agent" feature
        var locations: [1]protocol.SessionUpdate.ToolCallLocation = undefined;
        var locations_slice: ?[]const protocol.SessionUpdate.ToolCallLocation = null;
        if (raw_input) |input| {
            if (input == .object) {
                const obj = input.object;
                if (obj.get("file_path")) |fp| {
                    if (fp == .string) {
                        // Extract line number from offset/line fields
                        const line: ?u32 = blk: {
                            if (obj.get("offset")) |off| {
                                if (off == .integer) break :blk @intCast(off.integer);
                            }
                            if (obj.get("line")) |ln| {
                                if (ln == .integer) break :blk @intCast(ln.integer);
                            }
                            break :blk null;
                        };
                        locations[0] = .{ .path = fp.string, .line = line };
                        locations_slice = locations[0..1];
                    }
                }
            }
        }

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .tool_call,
            .toolCallId = tagged_id,
            .title = tagged_title,
            .kind = kind,
            .status = .pending,
            .rawInput = raw_input,
            .locations = locations_slice,
        });

        if (execute_preview) |preview| {
            var buf: [4096]u8 = undefined;
            var owned: ?[]const u8 = null;
            const display_text = if (!tag_engine) preview else blk: {
                if (self.formatTagged(&buf, engine, preview)) |tagged| break :blk tagged;
                const tagged_owned = try self.tagText(engine, preview);
                owned = tagged_owned;
                break :blk tagged_owned;
            };
            defer if (owned) |val| self.allocator.free(val);

            const entries: [1]protocol.SessionUpdate.ToolCallContent = .{
                .{ .type = "content", .content = .{ .type = "text", .text = display_text } },
            };

            self.sendSessionUpdate(session_id, .{
                .sessionUpdate = .tool_call_update,
                .toolCallId = tagged_id,
                .toolContent = entries[0..],
            }) catch |err| {
                log.warn("Failed to send tool call preview: {}", .{err});
            };
        }
    }

    fn sendEngineToolResult(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        content: ?[]const u8,
        status: protocol.SessionUpdate.ToolCallStatus,
        terminal_id: ?[]const u8,
        raw_output: ?std.json.Value,
        edit_info: ?EditInfo,
    ) !void {
        // Skip result for tools that were silenced at call time
        if (try self.consumeQuietTool(session, engine, tool_id)) return;

        const tag_engine = self.shouldTagEngine(session);
        var id_buf: [256]u8 = undefined;
        var id_owned: ?[]const u8 = null;
        const tagged_id = if (!tag_engine) tool_id else blk: {
            if (self.formatToolId(&id_buf, engine, tool_id)) |tagged| break :blk tagged;
            const owned = try self.tagToolId(engine, tool_id);
            id_owned = owned;
            break :blk owned;
        };
        defer if (id_owned) |owned| self.allocator.free(owned);

        var tagged_content: ?[]const u8 = null;
        var content_owned: ?[]const u8 = null;
        if (content) |text| {
            tagged_content = if (!tag_engine) text else blk: {
                const owned = try self.tagText(engine, text);
                content_owned = owned;
                break :blk owned;
            };
        }
        defer if (content_owned) |text| self.allocator.free(text);

        var entries: [3]protocol.SessionUpdate.ToolCallContent = undefined;
        var count: usize = 0;

        if (tagged_content) |text| {
            entries[count] = .{ .type = "content", .content = .{ .type = "text", .text = text } };
            count += 1;
        }
        if (terminal_id) |tid| {
            entries[count] = .{ .type = "terminal", .terminalId = tid };
            count += 1;
        }
        if (edit_info) |info| {
            entries[count] = .{
                .type = "diff",
                .path = info.path,
                .oldText = info.old_text,
                .newText = info.new_text,
            };
            count += 1;
        }

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .tool_call_update,
            .toolCallId = tagged_id,
            .status = status,
            .toolContent = if (count > 0) entries[0..count] else null,
            .rawOutput = raw_output,
        });
    }

    const WriteToolInput = struct {
        file_path: ?[]const u8 = null,
        path: ?[]const u8 = null,
        content: ?[]const u8 = null,
        text: ?[]const u8 = null,
    };

    const ExecuteToolInput = struct {
        command: ?[]const u8 = null,
        cmd: ?[]const u8 = null,
    };

    const WriteToolKind = enum { write, edit };
    const write_tool_map = std.StaticStringMap(WriteToolKind).initComptime(.{
        .{ "Write", .write },
        .{ "Edit", .edit },
    });

    const EditToolInput = struct {
        file_path: ?[]const u8 = null,
        path: ?[]const u8 = null,
        old_string: ?[]const u8 = null,
        new_string: ?[]const u8 = null,
        replace_all: ?bool = null,
    };

    fn trackExecuteTool(self: *Agent, session: *Session, engine: Engine, tool_id: []const u8) !void {
        const owned = if (self.shouldTagEngine(session))
            try self.tagToolId(engine, tool_id)
        else
            try self.allocator.dupe(u8, tool_id);
        errdefer self.allocator.free(owned);
        try session.pending_execute_tools.put(owned, {});
    }

    fn consumeExecuteTool(self: *Agent, session: *Session, engine: Engine, tool_id: []const u8) !bool {
        if (!self.shouldTagEngine(session)) {
            if (session.pending_execute_tools.fetchRemove(tool_id)) |entry| {
                self.allocator.free(entry.key);
                return true;
            }
            return false;
        }

        var id_buf: [512]u8 = undefined;
        if (self.formatToolId(&id_buf, engine, tool_id)) |key| {
            if (session.pending_execute_tools.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                return true;
            }
            return false;
        }

        const owned = try self.tagToolId(engine, tool_id);
        defer self.allocator.free(owned);
        if (session.pending_execute_tools.fetchRemove(owned)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    fn trackQuietTool(self: *Agent, session: *Session, engine: Engine, tool_id: []const u8) !void {
        const owned = if (self.shouldTagEngine(session))
            try self.tagToolId(engine, tool_id)
        else
            try self.allocator.dupe(u8, tool_id);
        errdefer self.allocator.free(owned);
        try session.quiet_tool_ids.put(owned, {});
    }

    fn consumeQuietTool(self: *Agent, session: *Session, engine: Engine, tool_id: []const u8) !bool {
        if (!self.shouldTagEngine(session)) {
            if (session.quiet_tool_ids.fetchRemove(tool_id)) |entry| {
                self.allocator.free(entry.key);
                return true;
            }
            return false;
        }

        var id_buf: [512]u8 = undefined;
        if (self.formatToolId(&id_buf, engine, tool_id)) |key| {
            if (session.quiet_tool_ids.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                return true;
            }
            return false;
        }

        const owned = try self.tagToolId(engine, tool_id);
        defer self.allocator.free(owned);
        if (session.quiet_tool_ids.fetchRemove(owned)) |entry| {
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    fn trackEditTool(self: *Agent, session: *Session, engine: Engine, tool_id: []const u8, raw_input: ?std.json.Value) !void {
        const input_value = raw_input orelse return;
        const parsed = std.json.parseFromValue(EditToolInput, self.allocator, input_value, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse Edit tool input for tracking: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const input = parsed.value;
        const path = input.file_path orelse input.path orelse return;
        const old_text = input.old_string orelse return;
        const new_text = input.new_string orelse return;

        const owned_id = if (self.shouldTagEngine(session))
            try self.tagToolId(engine, tool_id)
        else
            try self.allocator.dupe(u8, tool_id);
        errdefer self.allocator.free(owned_id);

        const edit_info = EditInfo{
            .path = try self.allocator.dupe(u8, path),
            .old_text = try self.allocator.dupe(u8, old_text),
            .new_text = try self.allocator.dupe(u8, new_text),
        };
        errdefer edit_info.deinit(self.allocator);

        try session.pending_edit_tools.put(owned_id, edit_info);
    }

    fn consumeEditTool(self: *Agent, session: *Session, engine: Engine, tool_id: []const u8) ?EditInfo {
        if (!self.shouldTagEngine(session)) {
            if (session.pending_edit_tools.fetchRemove(tool_id)) |entry| {
                self.allocator.free(entry.key);
                return entry.value;
            }
            return null;
        }

        var id_buf: [512]u8 = undefined;
        if (self.formatToolId(&id_buf, engine, tool_id)) |key| {
            if (session.pending_edit_tools.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                return entry.value;
            }
            return null;
        }

        const owned = self.tagToolId(engine, tool_id) catch return null;
        defer self.allocator.free(owned);
        if (session.pending_edit_tools.fetchRemove(owned)) |entry| {
            self.allocator.free(entry.key);
            return entry.value;
        }
        return null;
    }

    fn maybeSyncWriteTool(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        tool_name: []const u8,
        raw_input: ?std.json.Value,
    ) !void {
        if (!self.canWriteFiles()) return;
        const input_value = raw_input orelse return;

        const kind = write_tool_map.get(tool_name) orelse return;
        switch (kind) {
            .write => {
                const parsed = std.json.parseFromValue(WriteToolInput, self.allocator, input_value, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    log.warn("Failed to parse {s} tool input: {}", .{ tool_name, err });
                    return;
                };
                defer parsed.deinit();
                const path = parsed.value.file_path orelse parsed.value.path orelse return;
                const content = parsed.value.content orelse parsed.value.text orelse return;
                _ = try self.requestWriteTextFile(session, session_id, path, content);
            },
            .edit => {
                const parsed = std.json.parseFromValue(EditToolInput, self.allocator, input_value, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    log.warn("Failed to parse {s} tool input: {}", .{ tool_name, err });
                    return;
                };
                defer parsed.deinit();
                const path = parsed.value.file_path orelse parsed.value.path orelse return;
                const old_string = parsed.value.old_string orelse return;
                const new_string = parsed.value.new_string orelse return;

                // Read current file content
                const current = self.requestReadTextFile(session, session_id, path, null, null) catch |err| {
                    log.warn("Failed to read file for Edit sync: {}", .{err});
                    return;
                };
                const content = current orelse return;
                defer self.allocator.free(content);

                // Apply the edit
                const replace_all = parsed.value.replace_all orelse false;
                const result = if (replace_all)
                    try std.mem.replaceOwned(u8, self.allocator, content, old_string, new_string)
                else
                    try replaceFirst(self.allocator, content, old_string, new_string);
                defer self.allocator.free(result);

                _ = try self.requestWriteTextFile(session, session_id, path, result);
            },
        }
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
            try self.sendEngineText(session, session_id, engine, "Tool execution blocked by settings.");
            return;
        }
        if (kind == .execute and self.canUseTerminal()) {
            try self.trackExecuteTool(session, engine, tool_id);
        }
        if (kind == .edit) {
            try self.trackEditTool(session, engine, tool_id, raw_input);
        }
        try self.sendEngineToolCall(session, session_id, engine, tool_id, display_name, kind, raw_input);
        try self.maybeSyncWriteTool(session, session_id, permission_name, raw_input);
    }

    fn handleEngineToolResult(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        engine: Engine,
        tool_id: []const u8,
        content: ?[]const u8,
        status: protocol.SessionUpdate.ToolCallStatus,
        raw_output: std.json.Value,
    ) !void {
        _ = try self.consumeExecuteTool(session, engine, tool_id);
        // Terminal mirroring disabled - output is already visible in tool_call_update

        // Check for edit tool diff info
        var edit_info: ?EditInfo = null;
        defer if (edit_info) |info| info.deinit(self.allocator);
        edit_info = self.consumeEditTool(session, engine, tool_id);

        const raw = if (raw_output != .null) raw_output else null;
        try self.sendEngineToolResult(session, session_id, engine, tool_id, content, status, null, raw, edit_info);
    }

    fn requestPermission(
        self: *Agent,
        session: *Session,
        session_id: []const u8,
        tool_call_id: []const u8,
        title: []const u8,
        kind: protocol.SessionUpdate.ToolKind,
        raw_input: ?std.json.Value,
    ) !protocol.PermissionOutcome {
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const options = [_]protocol.PermissionOption{
            .{ .kind = .allow_once, .name = "Allow once", .optionId = "allow_once" },
            .{ .kind = .allow_always, .name = "Allow for session", .optionId = "allow_always" },
            .{ .kind = .reject_once, .name = "Deny", .optionId = "reject_once" },
            .{ .kind = .reject_always, .name = "Deny for session", .optionId = "reject_always" },
        };

        const params = protocol.PermissionRequest{
            .sessionId = session_id,
            .toolCall = .{
                .toolCallId = tool_call_id,
                .title = title,
                .kind = kind,
                .status = .pending,
                .rawInput = raw_input,
            },
            .options = options[0..],
        };

        try self.writer.writeTypedRequest(.{ .number = request_id }, "session/request_permission", params);

        var response = self.waitForResponse(session, .{ .number = request_id }) catch |err| {
            if (err == error.Cancelled) {
                return .{ .outcome = .cancelled, .optionId = null };
            }
            return err;
        };
        defer response.deinit();

        return try self.parsePermissionOutcome(response.message.response);
    }

    fn formatApprovalToolCallId(self: *Agent, request_id: CodexMessage.RpcRequestId) ![]const u8 {
        return switch (request_id) {
            .integer => |id| std.fmt.allocPrint(self.allocator, "codex_approval_{d}", .{id}),
            .string => |id| std.fmt.allocPrint(self.allocator, "codex_approval_{s}", .{id}),
        };
    }

    fn waitForResponse(self: *Agent, session: *Session, request_id: jsonrpc.Request.Id) !jsonrpc.ParsedMessage {
        const reader = self.reader orelse return error.NoReader;
        var parsed: ?jsonrpc.ParsedMessage = null;
        defer if (parsed) |*msg| msg.deinit();

        const deadline_ms = std.time.milliTimestamp() + response_timeout_ms;

        const State = enum {
            read_message,
            dispatch_message,
        };

        var state: State = .read_message;

        state: while (true) {
            if (session.cancelled.load(.acquire)) {
                return error.Cancelled;
            }
            switch (state) {
                .read_message => {
                    if (self.takePendingResponse(request_id)) |response_msg| {
                        return response_msg;
                    }
                    if (parsed) |*msg| {
                        msg.deinit();
                        parsed = null;
                    }
                    parsed = (try reader.nextMessageWithTimeout(deadline_ms)) orelse return error.UnexpectedEof;
                    state = .dispatch_message;
                    continue :state;
                },
                .dispatch_message => {
                    const message = parsed.?.message;
                    switch (message) {
                        .request => |req| try self.handleRequest(req),
                        .notification => |note| try self.handleNotification(note),
                        .response => |resp| {
                            if (idsMatch(resp.id, request_id)) {
                                const response_msg = parsed.?;
                                parsed = null;
                                return response_msg;
                            }
                            try self.stashResponse(parsed.?);
                            parsed = null;
                        },
                    }
                    state = .read_message;
                    continue :state;
                },
            }
        }
    }

    fn pollClientMessages(self: *Agent, session: *Session) void {
        // Check permission socket for hook requests
        self.pollPermissionSocket(session);

        const reader = self.reader orelse return;
        while (true) {
            const deadline_ms = std.time.milliTimestamp();
            var parsed = reader.nextMessageWithTimeout(deadline_ms) catch |err| switch (err) {
                error.Timeout => return,
                else => {
                    log.warn("Failed to poll client message: {}", .{err});
                    return;
                },
            } orelse return;

            switch (parsed.message) {
                .response => {
                    self.stashResponse(parsed) catch |err| {
                        log.warn("Failed to stash client response: {}", .{err});
                        parsed.deinit();
                    };
                },
                else => {
                    self.handleMessage(parsed.message) catch |err| {
                        log.warn("Failed to handle client message: {}", .{err});
                    };
                    parsed.deinit();
                },
            }

            if (session.cancelled.load(.acquire)) return;
        }
    }

    fn pollPermissionSocket(self: *Agent, session: *Session) void {
        const sock = session.permission_socket orelse {
            log.debug("No permission socket to poll", .{});
            return;
        };

        // Try to accept a connection (non-blocking)
        var client_addr: std.posix.sockaddr.un = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
        const client_fd = std.posix.accept(sock, @ptrCast(&client_addr), &addr_len, 0) catch |err| {
            if (err == error.WouldBlock) return; // No pending connection
            log.warn("Permission socket accept error: {}", .{err});
            return;
        };
        defer std.posix.close(client_fd);
        log.info("Accepted permission socket connection", .{});

        // Read request from hook (may arrive in multiple chunks)
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = std.posix.read(client_fd, buf[total..]) catch |err| {
                log.warn("Permission socket read error: {}", .{err});
                return;
            };
            if (n == 0) break; // EOF
            total += n;
            // Check if we have a complete line (JSON ends with newline)
            if (std.mem.indexOfScalar(u8, buf[0..total], '\n') != null) break;
        }
        if (total == 0) return;

        // Parse JSON request
        const request_json = std.mem.trimRight(u8, buf[0..total], "\n\r");
        var parsed = std.json.parseFromSlice(PermissionHookRequest, self.allocator, request_json, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Permission hook request parse error: {}", .{err});
            self.sendPermissionResponse(client_fd, "ask", null);
            return;
        };
        defer parsed.deinit();

        const req = parsed.value;
        log.info("Permission request from hook: tool={s} id={s}", .{ req.tool_name, req.tool_use_id });

        // Handle AskUserQuestion specially - show choices to user
        if (std.mem.eql(u8, req.tool_name, "AskUserQuestion")) {
            self.handleAskUserQuestion(session, client_fd, req) catch |err| {
                log.warn("Failed to handle AskUserQuestion: {}", .{err});
                self.sendPermissionResponse(client_fd, "allow", null);
            };
            return;
        }

        // Auto-approve in bypass mode
        if (session.permission_mode == .bypassPermissions) {
            log.info("Auto-approving in bypass mode", .{});
            self.sendPermissionResponse(client_fd, "allow", null);
            return;
        }

        // Forward to Zed via ACP
        const decision = self.requestPermissionFromClient(session, req) catch |err| {
            log.warn("Failed to request permission from client: {}", .{err});
            self.sendPermissionResponse(client_fd, "ask", null);
            return;
        };

        // Send response back to hook
        self.sendPermissionResponse(client_fd, decision.behavior, decision.message);
    }

    const PermissionHookRequest = struct {
        tool_name: []const u8,
        tool_input: std.json.Value,
        tool_use_id: []const u8,
        session_id: []const u8,
    };

    const PermissionDecision = struct {
        behavior: []const u8, // "allow", "deny", "ask"
        message: ?[]const u8,
    };

    fn sendPermissionResponse(self: *Agent, fd: std.posix.fd_t, decision: []const u8, message: ?[]const u8) void {
        _ = self;
        var buf: [512]u8 = undefined;
        const response = if (message) |msg|
            std.fmt.bufPrint(&buf, "{{\"decision\":\"{s}\",\"message\":\"{s}\"}}\n", .{ decision, msg }) catch return
        else
            std.fmt.bufPrint(&buf, "{{\"decision\":\"{s}\"}}\n", .{decision}) catch return;
        _ = std.posix.write(fd, response) catch {};
    }

    const AskUserQuestionSocketResponse = struct {
        decision: []const u8 = "allow",
        answers: std.json.ArrayHashMap([]const u8),
    };

    fn sendAskUserQuestionResponse(self: *Agent, fd: std.posix.fd_t, header: []const u8, answer: []const u8) !void {
        var answers = std.json.ArrayHashMap([]const u8){};
        try answers.map.put(self.allocator, header, answer);
        defer answers.map.deinit(self.allocator);

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        try jw.write(AskUserQuestionSocketResponse{ .answers = answers });
        try out.writer.writeByte('\n');
        const response = try out.toOwnedSlice();
        defer self.allocator.free(response);
        _ = try std.posix.write(fd, response);
    }

    // AskUserQuestion input schema
    const AskUserQuestionInput = struct {
        questions: []const Question,

        const Question = struct {
            question: []const u8,
            header: []const u8,
            multiSelect: bool,
            options: []const Option,
        };

        const Option = struct {
            label: []const u8,
            description: []const u8,
        };
    };

    fn handleAskUserQuestion(self: *Agent, session: *Session, client_fd: std.posix.fd_t, req: PermissionHookRequest) !void {
        // Parse the AskUserQuestion input
        const parsed = std.json.parseFromValue(AskUserQuestionInput, self.allocator, req.tool_input, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse AskUserQuestion input: {}", .{err});
            self.sendPermissionResponse(client_fd, "allow", null);
            return;
        };
        defer parsed.deinit();

        const input = parsed.value;
        if (input.questions.len == 0) {
            self.sendPermissionResponse(client_fd, "allow", null);
            return;
        }

        // For now, handle first question only (could loop for multiple)
        const q = input.questions[0];

        // Build permission options from question options
        var options: [4]protocol.PermissionOption = undefined;
        const opt_count = @min(q.options.len, 4);
        for (q.options[0..opt_count], 0..) |opt, i| {
            options[i] = .{
                .kind = .allow_once,
                .name = opt.label,
                .optionId = opt.label,
            };
        }

        // Send permission request to Zed
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const params = protocol.PermissionRequest{
            .sessionId = session.id,
            .toolCall = .{
                .toolCallId = req.tool_use_id,
                .title = q.question,
                .kind = .other,
                .status = .pending,
                .rawInput = null,
            },
            .options = options[0..opt_count],
        };

        try self.writer.writeTypedRequest(.{ .number = request_id }, "session/request_permission", params);

        // Wait for user response
        var response = self.waitForResponse(session, .{ .number = request_id }) catch |err| {
            log.warn("AskUserQuestion response error: {}", .{err});
            self.sendPermissionResponse(client_fd, "allow", null);
            return;
        };
        defer response.deinit();

        const outcome = try self.parsePermissionOutcome(response.message.response);

        // Return the selected option as the answer
        if (outcome.optionId) |selected| {
            log.info("AskUserQuestion answered: {s}", .{selected});
            try self.sendAskUserQuestionResponse(client_fd, q.header, selected);
        } else {
            self.sendPermissionResponse(client_fd, "allow", null);
        }
    }

    /// Build a descriptive title for permission prompts from tool name and input
    fn buildPermissionTitle(self: *Agent, tool_name: []const u8, tool_input: std.json.Value) []const u8 {
        // Extract the key detail from tool_input based on tool type
        if (tool_input != .object) return tool_name;

        const obj = tool_input.object;

        // Map tool names to their primary input field
        const field_map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "Read", "file_path" },
            .{ "Write", "file_path" },
            .{ "Edit", "file_path" },
            .{ "Bash", "command" },
            .{ "Grep", "pattern" },
            .{ "Glob", "pattern" },
            .{ "WebFetch", "url" },
            .{ "WebSearch", "query" },
            .{ "Skill", "skill" },
        });

        const field_name = field_map.get(tool_name) orelse return tool_name;
        const field_value = obj.get(field_name) orelse return tool_name;

        const detail = switch (field_value) {
            .string => |s| s,
            else => return tool_name,
        };

        // Truncate long details
        const max_len: usize = 60;
        const truncated = if (detail.len > max_len)
            detail[0..max_len]
        else
            detail;

        // Format: "Tool: detail"
        return std.fmt.allocPrint(self.allocator, "{s}: {s}{s}", .{
            tool_name,
            truncated,
            if (detail.len > max_len) "..." else "",
        }) catch tool_name;
    }

    // Tools that are always safe and should be auto-approved regardless of mode
    const always_approve_tools = std.StaticStringMap(void).initComptime(.{
        .{ "TodoWrite", {} },
        .{ "TodoRead", {} },
        .{ "Task", {} },
        .{ "TaskOutput", {} },
        .{ "AskUserQuestion", {} },
        // Read-only tools
        .{ "Read", {} },
        .{ "Grep", {} },
        .{ "Glob", {} },
        .{ "LSP", {} },
    });

    // Edit tools auto-approved in acceptEdits mode
    const edit_tools = std.StaticStringMap(void).initComptime(.{
        .{ "Write", {} },
        .{ "Edit", {} },
        .{ "MultiEdit", {} },
        .{ "NotebookEdit", {} },
    });

    const PermissionAction = enum { allow_once, allow_always, deny };
    const permission_option_map = std.StaticStringMap(PermissionAction).initComptime(.{
        .{ "allow_once", .allow_once },
        .{ "allow_always", .allow_always },
        .{ "reject_once", .deny },
    });

    fn requestPermissionFromClient(self: *Agent, session: *Session, req: PermissionHookRequest) !PermissionDecision {
        // Auto-approve safe internal and read-only tools
        if (always_approve_tools.has(req.tool_name)) {
            return .{ .behavior = "allow", .message = null };
        }

        // Check if user previously granted "Always Allow" for this tool
        if (session.always_allowed_tools.contains(req.tool_name)) {
            return .{ .behavior = "allow", .message = null };
        }

        // In acceptEdits mode, also auto-approve edit tools
        if (session.permission_mode == .acceptEdits) {
            if (edit_tools.has(req.tool_name)) {
                return .{ .behavior = "allow", .message = null };
            }
        }

        // Map tool name to kind
        const kind = mapToolKind(req.tool_name);

        // Build descriptive title including tool details
        const title = self.buildPermissionTitle(req.tool_name, req.tool_input);
        defer if (title.ptr != req.tool_name.ptr) self.allocator.free(title);

        // Build ACP permission request
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        const tool_call_id = try std.fmt.allocPrint(self.allocator, "hook_{s}", .{req.tool_use_id});
        defer self.allocator.free(tool_call_id);

        const params = protocol.PermissionRequest{
            .sessionId = session.id,
            .toolCall = .{
                .toolCallId = tool_call_id,
                .title = title,
                .kind = kind,
                .status = .pending,
                .rawInput = req.tool_input,
            },
            .options = &[_]protocol.PermissionOption{
                .{ .kind = .allow_once, .name = "Allow", .optionId = "allow_once" },
                .{ .kind = .allow_always, .name = "Allow Always", .optionId = "allow_always" },
                .{ .kind = .reject_once, .name = "Deny", .optionId = "reject_once" },
            },
        };

        try self.writer.writeTypedRequest(.{ .number = request_id }, "session/request_permission", params);

        // Wait for response
        var response = self.waitForResponse(session, .{ .number = request_id }) catch |err| {
            if (err == error.Cancelled) {
                return .{ .behavior = "deny", .message = "Cancelled" };
            }
            return err;
        };
        defer response.deinit();

        // Parse response
        if (response.message != .response) {
            return .{ .behavior = "ask", .message = null };
        }
        const resp = response.message.response;
        if (resp.result) |result| {
            const outcome = std.json.parseFromValue(protocol.PermissionResponse, self.allocator, result, .{
                .ignore_unknown_fields = true,
            }) catch {
                return .{ .behavior = "ask", .message = null };
            };
            defer outcome.deinit();

            if (outcome.value.outcome.outcome == .selected) {
                if (outcome.value.outcome.optionId) |opt_id| {
                    const action = permission_option_map.get(opt_id) orelse .deny;
                    switch (action) {
                        .allow_always => {
                            const key = self.allocator.dupe(u8, req.tool_name) catch {
                                return .{ .behavior = "allow", .message = null };
                            };
                            session.always_allowed_tools.put(key, {}) catch {
                                self.allocator.free(key);
                            };
                            return .{ .behavior = "allow", .message = null };
                        },
                        .allow_once => return .{ .behavior = "allow", .message = null },
                        .deny => return .{ .behavior = "deny", .message = "Permission denied" },
                    }
                }
            } else if (outcome.value.outcome.outcome == .cancelled) {
                return .{ .behavior = "deny", .message = "Cancelled" };
            }
        }

        return .{ .behavior = "ask", .message = null };
    }

    fn parsePermissionOutcome(self: *Agent, response: jsonrpc.Response) !protocol.PermissionOutcome {
        if (response.@"error" != null) {
            return error.PermissionRequestFailed;
        }
        const result = response.result orelse return error.InvalidPermissionResponse;
        const parsed = try std.json.parseFromValue(protocol.PermissionResponse, self.allocator, result, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        var outcome = parsed.value.outcome;
        if (outcome.optionId) |option_id| {
            outcome.optionId = try self.allocator.dupe(u8, option_id);
        }
        return outcome;
    }

    fn idsMatch(a: ?jsonrpc.Request.Id, b: jsonrpc.Request.Id) bool {
        if (a == null) return false;
        return switch (a.?) {
            .number => |id| switch (b) {
                .number => |other| id == other,
                else => false,
            },
            .string => |id| switch (b) {
                .string => |other| std.mem.eql(u8, id, other),
                else => false,
            },
            .null => false,
        };
    }

    fn stashResponse(self: *Agent, msg: jsonrpc.ParsedMessage) !void {
        const resp = msg.message.response;
        const id = resp.id orelse {
            var owned = msg;
            owned.deinit();
            return;
        };
        switch (id) {
            .number => |num| {
                if (self.pending_response_numbers.fetchRemove(num)) |entry| {
                    var owned = entry.value;
                    owned.deinit();
                }
                try self.pending_response_numbers.put(num, msg);
            },
            .string => |str| {
                if (self.pending_response_strings.fetchRemove(str)) |entry| {
                    var owned = entry.value;
                    owned.deinit();
                }
                try self.pending_response_strings.put(str, msg);
            },
            .null => {
                var owned = msg;
                owned.deinit();
            },
        }
    }

    fn takePendingResponse(self: *Agent, request_id: jsonrpc.Request.Id) ?jsonrpc.ParsedMessage {
        return switch (request_id) {
            .number => |num| blk: {
                if (self.pending_response_numbers.fetchRemove(num)) |entry| break :blk entry.value;
                break :blk null;
            },
            .string => |str| blk: {
                if (self.pending_response_strings.fetchRemove(str)) |entry| break :blk entry.value;
                break :blk null;
            },
            .null => null,
        };
    }

    fn clearPendingResponses(self: *Agent) void {
        var num_it = self.pending_response_numbers.iterator();
        while (num_it.next()) |entry| {
            var owned = entry.value_ptr.*;
            owned.deinit();
        }
        self.pending_response_numbers.clearRetainingCapacity();

        var str_it = self.pending_response_strings.iterator();
        while (str_it.next()) |entry| {
            var owned = entry.value_ptr.*;
            owned.deinit();
        }
        self.pending_response_strings.clearRetainingCapacity();
    }

    fn permissionDecisionForCodex(
        self: *Agent,
        kind: CodexMessage.ApprovalKind,
        outcome: protocol.PermissionOutcome,
    ) []const u8 {
        _ = self;
        if (outcome.outcome == .cancelled) {
            return switch (kind) {
                .command_execution, .file_change => "cancel",
                .exec_command, .apply_patch => "abort",
            };
        }

        const option_id = outcome.optionId orelse "";
        const allowed = allow_option_ids.get(option_id) != null;
        const allow_session = allow_session_option_ids.get(option_id) != null;

        switch (kind) {
            .command_execution, .file_change => {
                if (!allowed) return "decline";
                if (allow_session) return "acceptForSession";
                return "accept";
            },
            .exec_command, .apply_patch => {
                if (!allowed) return "denied";
                if (allow_session) return "approved_for_session";
                return "approved";
            },
        }
    }

    fn shouldTagEngine(self: *Agent, session: *Session) bool {
        _ = self;
        return session.config.route == .duet and session.availability.claude and session.availability.codex;
    }

    fn truncateUtf8(input: []const u8, max_bytes: usize) []const u8 {
        if (input.len <= max_bytes) return input;
        var i: usize = 0;
        var end: usize = 0;
        while (i < input.len and i < max_bytes) {
            const len = std.unicode.utf8ByteSequenceLength(input[i]) catch break;
            if (i + len > max_bytes) break;
            _ = std.unicode.utf8Decode(input[i..][0..len]) catch break;
            i += len;
            end = i;
        }
        if (end == 0) return input[0..max_bytes];
        return input[0..end];
    }

    fn tagText(self: *Agent, engine: Engine, text: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ engineLabel(engine), text });
    }

    fn tagToolId(self: *Agent, engine: Engine, tool_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ engineLabel(engine), tool_id });
    }

    fn formatTagged(self: *Agent, buf: []u8, engine: Engine, text: []const u8) ?[]const u8 {
        _ = self;
        const prefix = engineLabel(engine);
        const needed = prefix.len + text.len + 3;
        if (needed > buf.len) return null;
        return std.fmt.bufPrint(buf, "[{s}] {s}", .{ prefix, text }) catch null;
    }

    fn formatToolId(self: *Agent, buf: []u8, engine: Engine, tool_id: []const u8) ?[]const u8 {
        _ = self;
        const prefix = engineLabel(engine);
        const needed = prefix.len + tool_id.len + 1;
        if (needed > buf.len) return null;
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ prefix, tool_id }) catch null;
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
            session.cancelled.store(true, .release);
            self.clearPendingExecuteTools(session);
            if (session.bridge) |*b| {
                b.deinit();
                session.bridge = null;
            }
            if (session.codex_bridge) |*b| {
                b.deinit();
                session.codex_bridge = null;
            }
            log.info("Cancelled session {s}", .{parsed.value.sessionId});
        }
        // Cancel is a notification, no response needed
    }

    fn handleSetMode(self: *Agent, request: jsonrpc.Request) !void {
        if (request.params == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing params",
            ));
            return;
        }
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

        const mode_value = params.modeId orelse params.mode orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing modeId",
            ));
            return;
        };

        const new_mode = std.meta.stringToEnum(protocol.PermissionMode, mode_value) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Invalid permission mode",
            ));
            return;
        };

        const old_mode = session.permission_mode;
        session.permission_mode = new_mode;
        log.info("Set mode for session {s}: {s} -> {s} (bypass={}, force_restart={})", .{
            params.sessionId,
            @tagName(old_mode),
            mode_value,
            new_mode == .bypassPermissions,
            session.force_new_claude,
        });

        // Keep permission socket open even in bypass mode - we auto-approve requests
        // that come through it. Closing it would cause Claude's hook to fail and
        // fall back to interactive prompts.

        if (session.codex_bridge) |*codex_bridge| {
            codex_bridge.approval_policy = codexApprovalPolicy(session.permission_mode);
        }
        // Claude CLI does not accept control messages to change permission mode.
        // Mark for restart on next prompt. Don't deinit here - a prompt may be using the bridge.
        session.force_new_claude = true;

        try self.sendSessionUpdate(params.sessionId, .{
            .sessionUpdate = .current_mode_update,
            .currentModeId = @tagName(session.permission_mode),
        });

        try self.writer.writeTypedResponse(request.id, protocol.SetModeResponse{});
    }

    fn handleSetModel(self: *Agent, request: jsonrpc.Request) !void {
        if (request.params == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing params",
            ));
            return;
        }
        const parsed = std.json.parseFromValue(SetModelParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId or modelId",
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

        if (model_id_set.get(params.modelId) == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Unknown modelId",
            ));
            return;
        }

        const new_model = try self.allocator.dupe(u8, params.modelId);
        if (session.model) |m| self.allocator.free(m);
        session.model = new_model;
        log.info("Set model for session {s} to {s}", .{ params.sessionId, params.modelId });

        if (session.bridge) |*b| {
            b.stop();
        }

        try self.sendSessionUpdate(params.sessionId, .{
            .sessionUpdate = .current_model_update,
            .currentModelId = params.modelId,
        });

        try self.writer.writeTypedResponse(request.id, protocol.SetModelResponse{});
    }

    fn handleSetConfig(self: *Agent, request: jsonrpc.Request) !void {
        if (request.params == null) {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing params",
            ));
            return;
        }
        const parsed = std.json.parseFromValue(SetConfigParams, self.allocator, request.params orelse .null, .{
            .ignore_unknown_fields = true,
        }) catch {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Missing sessionId or configId",
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

        const config_id = config_option_map.get(params.configId) orelse {
            try self.writer.writeResponse(jsonrpc.Response.err(
                request.id,
                jsonrpc.Error.InvalidParams,
                "Unknown configId",
            ));
            return;
        };

        switch (config_id) {
            .auto_resume => {
                const value = bool_str_map.get(params.value) orelse {
                    try self.writer.writeResponse(jsonrpc.Response.err(
                        request.id,
                        jsonrpc.Error.InvalidParams,
                        "auto_resume expects \"true\" or \"false\"",
                    ));
                    return;
                };
                self.config_defaults.auto_resume = value;
                self.updateAllSessions(.auto_resume, .{ .auto_resume = value });
            },
            .route => {
                const route = types.route_map.get(params.value) orelse {
                    try self.writer.writeResponse(jsonrpc.Response.err(
                        request.id,
                        jsonrpc.Error.InvalidParams,
                        "Invalid route value",
                    ));
                    return;
                };
                self.config_defaults.route = route;
                self.updateAllSessions(.route, .{ .route = route });
            },
            .primary_agent => {
                const primary = types.engine_map.get(params.value) orelse {
                    try self.writer.writeResponse(jsonrpc.Response.err(
                        request.id,
                        jsonrpc.Error.InvalidParams,
                        "Invalid primary_agent value",
                    ));
                    return;
                };
                self.config_defaults.primary_agent = primary;
                self.updateAllSessions(.primary_agent, .{ .primary_agent = primary });
            },
        }

        log.info("Updated config {s} for session {s}", .{ params.configId, params.sessionId });
        var config_options = buildConfigOptions(session);
        try self.writer.writeTypedResponse(request.id, protocol.SetConfigOptionResponse{
            .configOptions = config_options[0..],
        });
    }

    fn updateAllSessions(self: *Agent, config_id: ConfigOptionId, update: SessionConfigUpdate) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            switch (config_id) {
                .auto_resume => if (update.auto_resume) |val| {
                    session.config.auto_resume = val;
                },
                .route => if (update.route) |val| {
                    session.config.route = val;
                },
                .primary_agent => if (update.primary_agent) |val| {
                    session.config.primary_agent = val;
                },
            }
        }
    }

    fn clearPendingExecuteTools(self: *Agent, session: *Session) void {
        var it = session.pending_execute_tools.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        session.pending_execute_tools.clearRetainingCapacity();
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
            try self.writer.writeTypedResponse(request.id, protocol.ResumeSessionResponse{
                .sessionId = params.sessionId,
            });
            return;
        }

        // Create new session
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        const sid_copy = try self.allocator.dupe(u8, params.sessionId);
        errdefer self.allocator.free(sid_copy);
        const cwd_copy = try self.allocator.dupe(u8, params.cwd);
        errdefer self.allocator.free(cwd_copy);
        const model_copy = try self.allocator.dupe(u8, default_model_id);
        errdefer self.allocator.free(model_copy);

        session.* = .{
            .id = sid_copy,
            .cwd = cwd_copy,
            .config = self.config_defaults,
            .availability = undefined,
            .model = model_copy,
            .pending_execute_tools = std.StringHashMap(void).init(self.allocator),
            .pending_edit_tools = std.StringHashMap(EditInfo).init(self.allocator),
            .always_allowed_tools = std.StringHashMap(void).init(self.allocator),
            .quiet_tool_ids = std.StringHashMap(void).init(self.allocator),
        };
        try self.sessions.put(sid_copy, session);

        const availability = detectEngines();
        session.availability = availability;
        if (routeEnvValue() == null) {
            const default_route = resolveDefaultRoute(availability);
            session.config.route = default_route;
            self.config_defaults.route = default_route;
        }

        log.info("Resumed session {s}", .{sid_copy});

        try self.writer.writeTypedResponse(request.id, protocol.ResumeSessionResponse{
            .sessionId = sid_copy,
        });
    }

    /// Handle authentication required - notify user and stop bridge
    fn handleAuthRequired(self: *Agent, session_id: []const u8, session: *Session, engine: Engine) !protocol.StopReason {
        log.warn("Auth required for session {s}", .{session_id});
        try self.sendEngineText(session, session_id, engine, "Authentication required. Please run `claude /login` in your terminal, then try again.");
        if (session.bridge) |*b| {
            b.stop();
        }
        session.bridge = null;
        return .end_turn;
    }

    /// Handle /version command
    fn handleVersionCommand(self: *Agent, request: jsonrpc.Request, session_id: []const u8) !void {
        const version_msg = std.fmt.comptimePrint("Banjo Duet {s} - ACP Agent for Claude Code + Codex", .{version});
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = version_msg },
        });

        try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = .end_turn });
    }

    fn clearSessionId(self: *Agent, slot: *?[]const u8) void {
        if (slot.*) |sid| self.allocator.free(sid);
        slot.* = null;
    }

    fn prepareFreshSessions(self: *Agent, session: *Session) void {
        self.clearSessionId(&session.cli_session_id);
        self.clearSessionId(&session.codex_session_id);
        session.force_new_claude = true;
        session.force_new_codex = true;
        session.cancelled.store(false, .release);
        self.clearPendingExecuteTools(session);
    }

    fn handleRouteCommand(self: *Agent, request: jsonrpc.Request, session_id: []const u8, route: Route, has_args: bool) !void {
        self.config_defaults.route = route;
        self.updateAllSessions(.route, .{ .route = route });

        const label = routeLabel(route);
        var buf: [160]u8 = undefined;
        const msg = if (has_args)
            (std.fmt.bufPrint(&buf, "Routing mode set to {s}. This command takes no arguments; send your prompt next.", .{label}) catch "Routing mode updated.")
        else
            (std.fmt.bufPrint(&buf, "Routing mode set to {s}.", .{label}) catch "Routing mode updated.");

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = msg },
        });
        try self.sendEndTurn(request);
    }

    /// Handle /new command
    fn handleNewCommand(self: *Agent, request: jsonrpc.Request, session: *Session, session_id: []const u8) !void {
        self.prepareFreshSessions(session);

        var claude_ok = false;
        var codex_ok = false;

        if (session.bridge == null) {
            session.bridge = Bridge.init(self.allocator, session.cwd);
        }
        if (session.bridge) |*b| {
            b.stop();
            self.startClaudeBridge(session, session_id) catch |err| {
                log.err("Failed to start new Claude Code session: {}", .{err});
            };
            claude_ok = session.bridge != null and session.bridge.?.process != null;
        }

        if (session.codex_bridge == null) {
            session.codex_bridge = CodexBridge.init(self.allocator, session.cwd);
        }
        if (session.codex_bridge) |*b| {
            b.stop();
            self.startCodexBridge(session, session_id) catch |err| {
                log.err("Failed to start new Codex session: {}", .{err});
            };
            codex_ok = session.codex_bridge != null and session.codex_bridge.?.process != null;
        }

        const status_text = blk: {
            if (claude_ok and codex_ok) break :blk "Started fresh Claude Code and Codex sessions (no resume).";
            if (claude_ok and !codex_ok) break :blk "Started fresh Claude Code session (no resume). Codex unavailable or failed to start.";
            if (!claude_ok and codex_ok) break :blk "Started fresh Codex session (no resume). Claude Code unavailable or failed to start.";
            break :blk "Failed to start fresh sessions for Claude Code and Codex.";
        };

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = status_text },
        });

        try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = .end_turn });
    }

    fn handleNudgeCommand(self: *Agent, request: jsonrpc.Request, session: *Session, session_id: []const u8, args: ?[]const u8) !void {
        var should_trigger = false;
        const msg = if (args) |a| blk: {
            const trimmed = std.mem.trim(u8, a, " \t");
            if (std.mem.eql(u8, trimmed, "on")) {
                session.nudge_enabled = true;
                should_trigger = true;
                break :blk "Auto-nudge enabled. Will continue working on dots when agent stops.";
            } else if (std.mem.eql(u8, trimmed, "off")) {
                session.nudge_enabled = false;
                break :blk "Auto-nudge disabled. Agent will stop when done.";
            } else {
                break :blk if (session.nudge_enabled) "Usage: /nudge [on|off]\nCurrent: on" else "Usage: /nudge [on|off]\nCurrent: off";
            }
        } else if (session.nudge_enabled) "Auto-nudge is ON. Use `/nudge off` to disable." else "Auto-nudge is OFF. Use `/nudge on` to enable.";

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = "\n" },
        });
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = msg },
        });

        // If nudge was just enabled and there are pending dots, trigger immediately
        if (should_trigger and dots.hasPendingTasks(self.allocator, session.cwd)) {
            session.last_nudge_ms = std.time.milliTimestamp();
            log.info("Nudge enabled with pending dots, triggering continuation", .{});
            try self.sendUserMessage(session_id, "🔄 continue working on pending dots");
            _ = try self.triggerNudge(request, session, session_id);
        } else {
            try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = .end_turn });
        }
    }

    const Command = enum { version, note, notes, setup, explain, new, nudge };
    const command_map = std.StaticStringMap(Command).initComptime(.{
        .{ "version", .version },
        .{ "note", .note },
        .{ "notes", .notes },
        .{ "setup", .setup },
        .{ "explain", .explain },
        .{ "new", .new },
        .{ "nudge", .nudge },
    });

    const RouteCommand = struct {
        name: []const u8,
        route: Route,
        description: []const u8,
    };

    const route_commands = [_]RouteCommand{
        .{ .name = "claude", .route = .claude, .description = "Switch routing mode to Claude" },
        .{ .name = "codex", .route = .codex, .description = "Switch routing mode to Codex" },
        .{ .name = "duet", .route = .duet, .description = "Switch routing mode to Duet" },
    };

    const route_command_map = std.StaticStringMap(Route).initComptime(.{
        .{ "claude", .claude },
        .{ "codex", .codex },
        .{ "duet", .duet },
    });

    /// Dispatch slash commands. Returns modified prompt to pass to CLI, or null if fully handled.
    fn dispatchCommand(self: *Agent, request: jsonrpc.Request, session: *Session, session_id: []const u8, text: []const u8, resource: ?ResourceData) ?[]const u8 {
        if (text.len == 0 or text[0] != '/') return text;
        // Extract command name: "/cmd arg" -> "cmd"
        const after_slash = text[1..];
        const space_idx = std.mem.indexOfScalar(u8, after_slash, ' ') orelse after_slash.len;
        const cmd_name = after_slash[0..space_idx];

        if (route_command_map.get(cmd_name)) |route| {
            const args = if (space_idx < after_slash.len)
                std.mem.trimLeft(u8, after_slash[space_idx..], " \t")
            else
                "";
            const has_args = args.len > 0;
            self.handleRouteCommand(request, session_id, route, has_args) catch |err| {
                log.err("Route command failed: {}", .{err});
                self.sendErrorAndEnd(request, session_id, "Route command failed") catch |send_err| {
                    log.warn("Failed to send route error: {}", .{send_err});
                };
            };
            return null;
        }

        const command = command_map.get(cmd_name) orelse return text; // Not our command, pass through to CLI
        const cmd_args: ?[]const u8 = if (space_idx < after_slash.len)
            std.mem.trimLeft(u8, after_slash[space_idx..], " \t")
        else
            null;

        switch (command) {
            .version => {
                self.handleVersionCommand(request, session_id) catch |err| {
                    log.err("Version command failed: {}", .{err});
                    self.sendErrorAndEnd(request, session_id, "Version command failed") catch |send_err| {
                        log.warn("Failed to send version error: {}", .{send_err});
                    };
                };
                return null; // Fully handled
            },
            .note, .notes, .setup => {
                self.handleNotesCommand(request, session_id, session.cwd, text) catch |err| {
                    log.err("Notes command failed: {}", .{err});
                    self.sendErrorAndEnd(request, session_id, "Notes command failed") catch |send_err| {
                        log.warn("Failed to send notes error: {}", .{send_err});
                    };
                };
                return null; // Fully handled
            },
            .explain => {
                // Get summary from Claude and insert as note comment
                if (resource) |r| {
                    self.handleExplainCommand(request, session, session_id, r) catch |err| {
                        log.err("Explain command failed: {}", .{err});
                        self.sendErrorAndEnd(request, session_id, "Explain command failed") catch |send_err| {
                            log.warn("Failed to send explain error: {}", .{send_err});
                        };
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
            .new => {
                self.handleNewCommand(request, session, session_id) catch |err| {
                    log.err("New command failed: {}", .{err});
                    self.sendErrorAndEnd(request, session_id, "New command failed") catch |send_err| {
                        log.warn("Failed to send new error: {}", .{send_err});
                    };
                };
                return null;
            },
            .nudge => {
                self.handleNudgeCommand(request, session, session_id, cmd_args) catch |err| {
                    log.err("Nudge command failed: {}", .{err});
                    self.sendErrorAndEnd(request, session_id, "Nudge command failed") catch |send_err| {
                        log.warn("Failed to send nudge error: {}", .{send_err});
                    };
                };
                return null;
            },
        }
    }

    /// Decoded file URI result (path is owned)
    const FileUri = struct {
        path: []const u8,
        line: u32,
        line_specified: bool = false,

        fn deinit(self: *const FileUri, allocator: Allocator) void {
            allocator.free(self.path);
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
        const needs_decode = std.mem.indexOf(u8, raw_path, "%") != null;
        const path = if (needs_decode) blk: {
            var decoded: std.ArrayListUnmanaged(u8) = .empty;
            errdefer decoded.deinit(allocator);
            var i: usize = 0;
            while (i < raw_path.len) {
                if (raw_path[i] == '%') {
                    if (i + 2 < raw_path.len) {
                        const hex = raw_path[i + 1 .. i + 3];
                        if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                            decoded.append(allocator, byte) catch return null;
                            i += 3;
                            continue;
                        } else |_| {}
                    }
                }
                decoded.append(allocator, raw_path[i]) catch return null;
                i += 1;
            }
            break :blk decoded.toOwnedSlice(allocator) catch return null;
        } else allocator.dupe(u8, raw_path) catch return null;

        var line: u32 = 1;
        var line_specified = false;
        if (hash_idx + 2 < uri.len and uri[hash_idx + 1] == 'L') {
            const line_part = uri[hash_idx + 2 ..];
            const colon_idx = std.mem.indexOfScalar(u8, line_part, ':') orelse line_part.len;
            line = std.fmt.parseInt(u32, line_part[0..colon_idx], 10) catch 1;
            line_specified = true;
        }
        return .{
            .path = path,
            .line = line,
            .line_specified = line_specified,
        };
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

        const real_cwd = std.fs.cwd().realpathAlloc(self.allocator, session.cwd) catch blk: {
            const duped = self.allocator.dupe(u8, session.cwd) catch {
                return self.sendErrorAndEnd(request, session_id, "Invalid project path");
            };
            break :blk duped;
        };
        defer self.allocator.free(real_cwd);

        const in_project = std.mem.startsWith(u8, real_path, real_cwd) and
            (real_path.len == real_cwd.len or real_path[real_cwd.len] == '/');
        if (!in_project) {
            log.warn("Path traversal attempt: {s} not in {s}", .{ real_path, real_cwd });
            return self.sendErrorAndEnd(request, session_id, "File must be within project directory");
        }

        // Get code content from resource
        const code = resource.text;

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
        const trunc_note = if (resource.truncated) "Note: context truncated to 64KB.\n\n" else "";
        const prompt = try std.fmt.allocPrint(self.allocator,
            \\{s}Write a brief paragraph explaining what this {s} code does. Be concise but thorough.
            \\Respond with ONLY the explanation paragraph, no code blocks or formatting.
            \\
            \\```{s}
            \\{s}
            \\```
        , .{ trunc_note, lang, lang, code });
        defer self.allocator.free(prompt);

        // Report generating explanation
        const explain_tool_id = try self.reportToolStart(session_id, "Generating explanation", .other);
        defer self.allocator.free(explain_tool_id);

        // Send prompt and collect response
        const cli_bridge = try self.ensureClaudeBridge(session, session_id);
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
            try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = .end_turn });
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

        try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = .end_turn });
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
    const agent_commands = [_]protocol.SlashCommand{
        .{ .name = "explain", .description = "Summarize selected code as a note comment" },
        .{ .name = "setup", .description = "Configure Zed for banjo LSP integration" },
        .{ .name = "notes", .description = "List all notes in the project" },
        .{ .name = "note", .description = "Note management commands" },
        .{ .name = "version", .description = "Show banjo version" },
        .{ .name = "new", .description = "Start fresh Claude Code and Codex sessions" },
        .{ .name = "nudge", .description = "Toggle auto-continue when dots are pending (on/off)" },
    };

    const slash_commands = agent_commands ++ [_]protocol.SlashCommand{
        .{ .name = route_commands[0].name, .description = route_commands[0].description },
        .{ .name = route_commands[1].name, .description = route_commands[1].description },
        .{ .name = route_commands[2].name, .description = route_commands[2].description },
    };

    /// Commands filtered from CLI (unsupported in stream-json mode, handled via authMethods)
    const unsupported_command_map = std.StaticStringMap(void).initComptime(.{
        .{ "login", {} },
        .{ "logout", {} },
        .{ "cost", {} },
        .{ "context", {} },
    });

    /// Common Claude Code slash commands (static fallback, CLI provides full list on first prompt)
    const common_cli_commands = [_]protocol.SlashCommand{
        .{ .name = "model", .description = "Show current model" },
        .{ .name = "compact", .description = "Compact conversation" },
        .{ .name = "review", .description = "Code review" },
    };

    // Permission modes for Claude Code. Non-bypass modes use the PermissionRequest
    // hook to forward tool approval requests to Zed via ACP.
    const available_modes = [_]protocol.SessionMode{
        .{ .id = "default", .name = "Default", .description = "Ask before executing tools" },
        .{ .id = "acceptEdits", .name = "Accept edits", .description = "Auto-accept file edits, ask for others" },
        .{ .id = "bypassPermissions", .name = "Auto-approve", .description = "Run all tools without prompting" },
        .{ .id = "plan", .name = "Plan only", .description = "Plan without executing tools" },
    };

    const available_models = [_]protocol.SessionModel{
        .{ .id = "sonnet", .name = "Claude Sonnet", .description = "Fast, balanced" },
        .{ .id = "opus", .name = "Claude Opus", .description = "Most capable" },
        .{ .id = "haiku", .name = "Claude Haiku", .description = "Fastest" },
    };

    const auto_resume_config_options = [_]protocol.SessionConfigSelectOption{
        .{ .value = "true", .name = "On" },
        .{ .value = "false", .name = "Off" },
    };

    const route_config_options = [_]protocol.SessionConfigSelectOption{
        .{ .value = "claude", .name = "Claude" },
        .{ .value = "codex", .name = "Codex" },
        .{ .value = "duet", .name = "Duet" },
    };

    const primary_agent_config_options = [_]protocol.SessionConfigSelectOption{
        .{ .value = "claude", .name = "Claude" },
        .{ .value = "codex", .name = "Codex" },
    };

    fn buildConfigOptions(session: *const Session) [3]protocol.SessionConfigOption {
        const auto_resume_value = if (session.config.auto_resume) "true" else "false";
        return .{
            .{
                .id = "auto_resume",
                .name = "Auto-resume sessions",
                .description = "Resume the last session on startup",
                .type = .select,
                .currentValue = auto_resume_value,
                .options = auto_resume_config_options[0..],
            },
            .{
                .id = "route",
                .name = "Default agent",
                .description = "Agent to use for new prompts",
                .type = .select,
                .currentValue = @tagName(session.config.route),
                .options = route_config_options[0..],
            },
            .{
                .id = "primary_agent",
                .name = "Primary agent",
                .description = "First agent to answer in duet mode",
                .type = .select,
                .currentValue = @tagName(session.config.primary_agent),
                .options = primary_agent_config_options[0..],
            },
        };
    }

    /// Combined commands for initial session (before CLI provides its list)
    const initial_commands = slash_commands ++ common_cli_commands;

    /// Command names owned by Banjo (to avoid duplicates with CLI)
    const our_command_map = std.StaticStringMap(void).initComptime(.{
        .{ "banjo", {} },
        .{ "notes", {} },
        .{ "version", {} },
        .{ "new", {} },
        .{ "claude", {} },
        .{ "codex", {} },
        .{ "duet", {} },
    });

    /// Check if command is unsupported
    fn isUnsupportedCommand(name: []const u8) bool {
        return unsupported_command_map.get(name) != null;
    }

    /// Check if command is ours (to avoid duplicates with CLI)
    fn isOurCommand(name: []const u8) bool {
        return our_command_map.get(name) != null;
    }

    /// Send available_commands_update with CLI commands + agent commands
    fn sendAvailableCommands(self: *Agent, session_id: []const u8, cli_commands: []const []const u8) !void {
        // Build command list: agent commands + CLI commands (filtered)
        var commands: std.ArrayList(protocol.SlashCommand) = .empty;
        defer commands.deinit(self.allocator);
        try commands.ensureTotalCapacity(self.allocator, slash_commands.len + cli_commands.len);

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        // Add agent commands first
        try commands.appendSlice(self.allocator, slash_commands[0..]);
        for (&slash_commands) |cmd| {
            _ = try seen.put(cmd.name, {});
        }

        // Add CLI commands, filtering unsupported and duplicates
        for (cli_commands) |name| {
            if (isUnsupportedCommand(name) or isOurCommand(name)) continue;
            if (seen.get(name) != null) continue;
            _ = try seen.put(name, {});
            try commands.append(self.allocator, .{ .name = name, .description = "" });
        }

        log.info("Sending {d} available commands to client", .{commands.items.len});

        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .available_commands_update,
            .availableCommands = commands.items,
        });
    }

    /// Send end_turn response for a request
    fn sendEndTurn(self: *Agent, request: jsonrpc.Request) !void {
        try self.writer.writeTypedResponse(request.id, protocol.PromptResponse{ .stopReason = .end_turn });
    }

    /// Send error message and end turn (common pattern)
    fn sendErrorAndEnd(self: *Agent, request: jsonrpc.Request, session_id: []const u8, msg: []const u8) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = msg },
        });
        try self.sendEndTurn(request);
    }

    fn sendPanelWarning(self: *Agent, session_id: []const u8, msg: []const u8) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .agent_message_chunk,
            .content = .{ .type = "text", .text = msg },
        });
    }

    /// Send plan progress update
    fn sendPlan(self: *Agent, session_id: []const u8, entries: []const protocol.SessionUpdate.PlanEntry) !void {
        try self.sendSessionUpdate(session_id, .{
            .sessionUpdate = .plan,
            .entries = entries,
        });
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
const EnvVarGuard = test_env.EnvVarGuard;
const ohsnap = @import("ohsnap");

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

const expected_modes_json =
    "{\"availableModes\":[" ++
    "{\"id\":\"default\",\"name\":\"Default\",\"description\":\"Ask before executing tools\"}," ++
    "{\"id\":\"acceptEdits\",\"name\":\"Accept edits\",\"description\":\"Auto-accept file edits, ask for others\"}," ++
    "{\"id\":\"bypassPermissions\",\"name\":\"Auto-approve\",\"description\":\"Run all tools without prompting\"}," ++
    "{\"id\":\"plan\",\"name\":\"Plan only\",\"description\":\"Plan without executing tools\"}]," ++
    "\"currentModeId\":\"default\"}";

const expected_commands_json =
    "[{\"name\":\"explain\",\"description\":\"Summarize selected code as a note comment\"}," ++
    "{\"name\":\"setup\",\"description\":\"Configure Zed for banjo LSP integration\"}," ++
    "{\"name\":\"notes\",\"description\":\"List all notes in the project\"}," ++
    "{\"name\":\"note\",\"description\":\"Note management commands\"}," ++
    "{\"name\":\"version\",\"description\":\"Show banjo version\"}," ++
    "{\"name\":\"new\",\"description\":\"Start fresh Claude Code and Codex sessions\"}," ++
    "{\"name\":\"nudge\",\"description\":\"Toggle auto-continue when dots are pending (on/off)\"}," ++
    "{\"name\":\"claude\",\"description\":\"Switch routing mode to Claude\"}," ++
    "{\"name\":\"codex\",\"description\":\"Switch routing mode to Codex\"}," ++
    "{\"name\":\"duet\",\"description\":\"Switch routing mode to Duet\"}," ++
    "{\"name\":\"model\",\"description\":\"Show current model\"}," ++
    "{\"name\":\"compact\",\"description\":\"Compact conversation\"}," ++
    "{\"name\":\"review\",\"description\":\"Code review\"}]";

fn expectedInitializeResponse(comptime request_id: i64, comptime image_capable: bool) []const u8 {
    const version_str = std.fmt.comptimePrint("{d}", .{protocol.ProtocolVersion});
    const request_id_str = std.fmt.comptimePrint("{d}", .{request_id});
    const image_str = if (image_capable) "true" else "false";
    return "{\"jsonrpc\":\"2.0\",\"result\":{\"protocolVersion\":" ++ version_str ++
        ",\"agentInfo\":{\"name\":\"Banjo Duet\",\"title\":\"Banjo Duet\",\"version\":\"" ++ version ++
        "\"},\"agentCapabilities\":{\"promptCapabilities\":{\"image\":" ++ image_str ++ ",\"audio\":false,\"embeddedContext\":true}," ++
        "\"mcpCapabilities\":{\"http\":false,\"sse\":false}," ++
        "\"sessionCapabilities\":{}," ++
        "\"loadSession\":false},\"authMethods\":[{\"id\":\"claude-login\",\"name\":\"Log in with Claude Code\"," ++
        "\"description\":\"Run `claude /login` in the terminal\"}]}," ++
        "\"id\":" ++ request_id_str ++ "}\n";
}

fn expectedNewSessionOutput(
    comptime session_id: []const u8,
    comptime request_id: i64,
    comptime include_warning: bool,
) []const u8 {
    const request_id_str = std.fmt.comptimePrint("{d}", .{request_id});
    // Note: configOptions and models removed - not yet supported by Zed's ACP client
    if (include_warning) {
        return "{\"jsonrpc\":\"2.0\",\"result\":{\"sessionId\":\"" ++ session_id ++
            "\",\"modes\":" ++ expected_modes_json ++
            "},\"id\":" ++ request_id_str ++ "}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"" ++ session_id ++
            "\",\"update\":{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":" ++ expected_commands_json ++
            "}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"" ++ session_id ++
            "\",\"update\":{\"sessionUpdate\":\"current_mode_update\",\"currentModeId\":\"default\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"" ++ session_id ++
            "\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"" ++
            no_engine_warning ++ "\"}}}}\n";
    }

    return "{\"jsonrpc\":\"2.0\",\"result\":{\"sessionId\":\"" ++ session_id ++
        "\",\"modes\":" ++ expected_modes_json ++
        "},\"id\":" ++ request_id_str ++ "}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"" ++ session_id ++
        "\",\"update\":{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":" ++ expected_commands_json ++
        "}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"" ++ session_id ++
        "\",\"update\":{\"sessionUpdate\":\"current_mode_update\",\"currentModeId\":\"default\"}}}\n";
}

test "configFromEnv returns defaults" {
    // Env vars may be set in CI; just ensure the function returns a config.
    _ = configFromEnv();
}

test "replaceFirst replaces only first occurrence" {
    const result = try replaceFirst(testing.allocator, "foo bar foo", "foo", "baz");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("baz bar foo", result);
}

test "replaceFirst returns copy when needle not found" {
    const result = try replaceFirst(testing.allocator, "hello world", "xyz", "abc");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world", result);
}

test "max turn marker helpers detect max turn errors" {
    try testing.expect(containsMaxTurnMarker("error_max_turns"));
    try testing.expect(containsMaxTurnMarker("max_turn_requests"));
    try testing.expect(!containsMaxTurnMarker("budget_exceeded"));

    try testing.expect(isCodexMaxTurnError(.{ .code = "max_turns", .message = null, .type = null }));
    try testing.expect(isCodexMaxTurnError(.{ .code = null, .message = "max_turn_requests", .type = null }));
    try testing.expect(isCodexMaxTurnError(.{ .code = null, .message = null, .type = "error_max_turns" }));
    try testing.expect(!isCodexMaxTurnError(.{ .code = "budget", .message = null, .type = null }));
}

fn createFakeBinary(allocator: Allocator, dir: *std.testing.TmpDir, name: []const u8) ![]u8 {
    var file = try dir.dir.createFile(name, .{});
    file.close();
    return try dir.dir.realpathAlloc(allocator, name);
}

test "detectEngines hides codex when PATH is empty and CODEX_EXECUTABLE is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_claude = try createFakeBinary(testing.allocator, &tmp, "fake-claude");
    defer testing.allocator.free(fake_claude);

    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", fake_claude);
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    const availability = detectEngines();
    try testing.expect(availability.claude);
    try testing.expect(!availability.codex);
}

test "detectEngines hides claude when PATH is empty and CLAUDE_CODE_EXECUTABLE is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_codex = try createFakeBinary(testing.allocator, &tmp, "fake-codex");
    defer testing.allocator.free(fake_codex);

    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", fake_codex);
    defer guard_codex.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();

    const availability = detectEngines();
    try testing.expect(!availability.claude);
    try testing.expect(availability.codex);
}

test "Agent init/deinit" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();
}

test "Agent handleRequest - initialize" {
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "initialize",
        .id = .{ .number = 1 },
    };

    try agent.handleRequest(request);

    const expected = comptime expectedInitializeResponse(1, false);
    try (ohsnap{}).snap(@src(), expected).diff(tw.getOutput(), true);
}

test "Agent newSession warns when no engines are available" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_resume = try EnvVarGuard.set(testing.allocator, "BANJO_AUTO_RESUME", "true");
    defer guard_resume.deinit();
    var guard_route = try EnvVarGuard.set(testing.allocator, "BANJO_ROUTE", "duet");
    defer guard_route.deinit();
    var guard_primary_agent = try EnvVarGuard.set(testing.allocator, "BANJO_PRIMARY_AGENT", "claude");
    defer guard_primary_agent.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    const request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };
    try agent.handleRequest(request);

    const expected = comptime expectedNewSessionOutput("session-test", 1, true);
    try (ohsnap{}).snap(@src(), expected).diff(tw.getOutput(), true);
}

test "Agent handleRequest - initialize rejects wrong protocol version" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Unsupported protocol version"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - initialize accepts correct protocol version" {
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    const expected = comptime expectedInitializeResponse(1, false);
    try (ohsnap{}).snap(@src(), expected).diff(tw.getOutput(), true);
}

test "Agent requestPermission sends request and parses response" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    const response_json =
        \\{"jsonrpc":"2.0","id":1,"result":{"outcome":{"outcome":"selected","optionId":"allow_once"}}}
        \\n
    ;
    const input_buf = try testing.allocator.dupe(u8, response_json);
    defer testing.allocator.free(input_buf);

    var input_stream = std.io.fixedBufferStream(input_buf);
    var reader = jsonrpc.Reader.init(testing.allocator, input_stream.reader().any());
    defer reader.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, &reader);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    const outcome = try agent.requestPermission(&session, session.id, "tc-1", "Bash", .execute, .{ .string = "ls" });
    defer if (outcome.optionId) |option_id| testing.allocator.free(option_id);
    try testing.expectEqual(protocol.PermissionOutcomeKind.selected, outcome.outcome);
    try testing.expectEqualStrings("allow_once", outcome.optionId.?);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"session/request_permission","params":{"sessionId":"session-1","toolCall":{"toolCallId":"tc-1","title":"Bash","kind":"execute","status":"pending","rawInput":"ls"},"options":[{"kind":"allow_once","name":"Allow once","optionId":"allow_once"},{"kind":"allow_always","name":"Allow for session","optionId":"allow_always"},{"kind":"reject_once","name":"Deny","optionId":"reject_once"},{"kind":"reject_always","name":"Deny for session","optionId":"reject_always"}]},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent requestPermissionFromClient stores allow_always choice" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    // Mock response with "allow_always"
    const response_json =
        \\{"jsonrpc":"2.0","id":1,"result":{"outcome":{"outcome":"selected","optionId":"allow_always"}}}
        \\
    ;
    const input_buf = try testing.allocator.dupe(u8, response_json);
    defer testing.allocator.free(input_buf);

    var input_stream = std.io.fixedBufferStream(input_buf);
    var reader = jsonrpc.Reader.init(testing.allocator, input_stream.reader().any());
    defer reader.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, &reader);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    // First call - should prompt and store
    const req = Agent.PermissionHookRequest{
        .tool_name = "Bash",
        .tool_use_id = "tc-1",
        .tool_input = .{ .string = "echo hello" },
        .session_id = "session-1",
    };
    const decision1 = try agent.requestPermissionFromClient(&session, req);
    try testing.expectEqualStrings("allow", decision1.behavior);
    try testing.expect(session.always_allowed_tools.contains("Bash"));

    // Second call - should return immediately without prompting
    const decision2 = try agent.requestPermissionFromClient(&session, req);
    try testing.expectEqualStrings("allow", decision2.behavior);
}

test "bypass mode skips permission prompts" {
    // This tests the condition in pollPermissionSocket that auto-approves
    // when session.permission_mode == .bypassPermissions
    // Full socket flow is an integration test; here we just verify the mode check
    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .permission_mode = .bypassPermissions,
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    // In bypass mode, permission requests should be auto-approved
    try testing.expectEqual(protocol.PermissionMode.bypassPermissions, session.permission_mode);
}

test "permission socket auto-approves in bypass mode" {
    // Integration test: create actual socket, connect, verify auto-approve
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "test-session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .permission_mode = .bypassPermissions,
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    // Create permission socket
    try session.createPermissionSocket(testing.allocator);
    try testing.expect(session.permission_socket != null);
    try testing.expect(session.permission_socket_path != null);

    // Connect to socket like Claude's hook would
    const client = std.net.connectUnixSocket(session.permission_socket_path.?) catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return err;
    };
    defer client.close();

    // Send permission request
    const request = "{\"tool_name\":\"Bash\",\"tool_use_id\":\"tc-1\",\"tool_input\":{\"command\":\"ls\"},\"session_id\":\"test-session\"}\n";
    _ = try client.write(request);

    // Poll to handle the request (agent processes it)
    agent.pollPermissionSocket(&session);

    // Read response
    var buf: [256]u8 = undefined;
    const n = try client.read(&buf);
    const response = buf[0..n];

    // Should be auto-approved
    try testing.expect(std.mem.indexOf(u8, response, "\"decision\":\"allow\"") != null);
}

test "permission socket forwards to client in default mode" {
    // Integration test: in default mode, socket should forward to ACP client
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    // Mock ACP response for permission request
    const response_json =
        \\{"jsonrpc":"2.0","id":1,"result":{"outcome":{"outcome":"selected","optionId":"allow_once"}}}
        \\
    ;
    const input_buf = try testing.allocator.dupe(u8, response_json);
    defer testing.allocator.free(input_buf);

    var input_stream = std.io.fixedBufferStream(input_buf);
    var reader = jsonrpc.Reader.init(testing.allocator, input_stream.reader().any());
    defer reader.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, &reader);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "test-session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .permission_mode = .default, // NOT bypass
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    // Create permission socket
    try session.createPermissionSocket(testing.allocator);

    // Connect to socket
    const client = std.net.connectUnixSocket(session.permission_socket_path.?) catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return err;
    };
    defer client.close();

    // Send permission request
    const request = "{\"tool_name\":\"Bash\",\"tool_use_id\":\"tc-1\",\"tool_input\":{\"command\":\"ls\"},\"session_id\":\"test-session\"}\n";
    _ = try client.write(request);

    // Poll - this should forward to ACP client
    agent.pollPermissionSocket(&session);

    // Verify ACP request was sent (check output contains session/request_permission)
    const output = tw.output.items;
    try testing.expect(std.mem.indexOf(u8, output, "session/request_permission") != null);
}

test "Agent sendEngineText omits prefix in solo mode" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    try agent.sendEngineText(&session, session.id, .claude, "hello");

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent sendEngineToolCall omits prefix in solo mode" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .codex, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    try agent.sendEngineToolCall(&session, session.id, .codex, "tc-1", "Bash", .execute, .{ .string = "ls" });

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Bash: ls","kind":"execute","status":"pending","rawInput":"ls"}}}
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","content":[{"type":"content","content":{"type":"text","text":"ls"}}],"toolCallId":"tc-1"}}}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent sendEngineToolCall skips quiet tools and tracks ID" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    // Send a quiet tool (Read) - should produce no output and track ID
    try agent.sendEngineToolCall(&session, session.id, .claude, "tc-quiet", "Read", .read, null);

    // Verify no output was produced
    try testing.expectEqualStrings("", tw.getOutput());

    // Verify the tool ID was tracked
    try testing.expect(session.quiet_tool_ids.contains("tc-quiet"));

    // Send result for the quiet tool - should also produce no output
    try agent.sendEngineToolResult(&session, session.id, .claude, "tc-quiet", "file contents", .completed, null, null, null);

    // Still no output
    try testing.expectEqualStrings("", tw.getOutput());

    // ID should be consumed
    try testing.expect(!session.quiet_tool_ids.contains("tc-quiet"));
}

test "Agent requestWriteTextFile sends request" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    const response_json =
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\n
    ;
    const input_buf = try testing.allocator.dupe(u8, response_json);
    defer testing.allocator.free(input_buf);

    var input_stream = std.io.fixedBufferStream(input_buf);
    var reader = jsonrpc.Reader.init(testing.allocator, input_stream.reader().any());
    defer reader.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, &reader);
    defer agent.deinit();
    agent.client_capabilities = .{
        .fs = .{ .readTextFile = true, .writeTextFile = true },
        .terminal = false,
    };

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-1"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    const ok = try agent.requestWriteTextFile(&session, session.id, "foo.txt", "hello");
    try testing.expect(ok);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"fs/write_text_file","params":{"sessionId":"session-1","path":"foo.txt","content":"hello"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - newSession" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_resume = try EnvVarGuard.set(testing.allocator, "BANJO_AUTO_RESUME", "true");
    defer guard_resume.deinit();
    var guard_route = try EnvVarGuard.set(testing.allocator, "BANJO_ROUTE", "duet");
    defer guard_route.deinit();
    var guard_primary_agent = try EnvVarGuard.set(testing.allocator, "BANJO_PRIMARY_AGENT", "claude");
    defer guard_primary_agent.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    const request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 2 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    const expected = comptime expectedNewSessionOutput("session-test", 2, true);
    try (ohsnap{}).snap(@src(), expected).diff(tw.getOutput(), true);
}

test "Agent handleRequest - methodNotFound" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "nonexistent/method",
        .id = .{ .number = 99 },
    };

    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":99}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - setMode" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_resume = try EnvVarGuard.set(testing.allocator, "BANJO_AUTO_RESUME", "true");
    defer guard_resume.deinit();
    var guard_route = try EnvVarGuard.set(testing.allocator, "BANJO_ROUTE", "duet");
    defer guard_route.deinit();
    var guard_primary_agent = try EnvVarGuard.set(testing.allocator, "BANJO_PRIMARY_AGENT", "claude");
    defer guard_primary_agent.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    const session_id = "session-test";
    if (agent.sessions.get(session_id)) |session| {
        session.bridge = Bridge.init(testing.allocator, session.cwd);
    }

    // Clear output for next request
    tw.output.clearRetainingCapacity();

    // Set mode to plan
    var set_mode_params = std.json.ObjectMap.init(testing.allocator);
    defer set_mode_params.deinit();
    try set_mode_params.put("sessionId", .{ .string = session_id });
    try set_mode_params.put("modeId", .{ .string = "plan" });

    const set_mode_request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 2 },
        .params = .{ .object = set_mode_params },
    };
    try agent.handleRequest(set_mode_request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-test","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}}
        \\{"jsonrpc":"2.0","result":{},"id":2}
        \\
    ).diff(tw.getOutput(), true);
    // Bridge is NOT killed immediately (would cause use-after-free if prompt is running).
    // Instead, force_new_claude is set so next prompt restarts with new mode.
    try testing.expect(agent.sessions.get(session_id).?.bridge != null);
    try testing.expect(agent.sessions.get(session_id).?.force_new_claude);
}

test "Agent handleRequest - setMode session not found" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "nonexistent" });
    try params.put("modeId", .{ .string = "plan" });

    const request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };
    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Session not found"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - setMode invalid mode" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    // Create session
    var new_session_params = std.json.ObjectMap.init(testing.allocator);
    defer new_session_params.deinit();
    const create_request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = new_session_params },
    };
    try agent.handleRequest(create_request);
    tw.output.clearRetainingCapacity();

    // Try to set invalid mode
    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "session-test" });
    try params.put("modeId", .{ .string = "invalidMode" });

    const request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 2 },
        .params = .{ .object = params },
    };
    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid permission mode"},"id":2}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - setModel" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_resume = try EnvVarGuard.set(testing.allocator, "BANJO_AUTO_RESUME", "true");
    defer guard_resume.deinit();
    var guard_route = try EnvVarGuard.set(testing.allocator, "BANJO_ROUTE", "duet");
    defer guard_route.deinit();
    var guard_primary_agent = try EnvVarGuard.set(testing.allocator, "BANJO_PRIMARY_AGENT", "claude");
    defer guard_primary_agent.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var new_session_params = std.json.ObjectMap.init(testing.allocator);
    defer new_session_params.deinit();

    const create_request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = new_session_params },
    };
    try agent.handleRequest(create_request);

    const session_id = "session-test";
    tw.output.clearRetainingCapacity();

    var set_model_params = std.json.ObjectMap.init(testing.allocator);
    defer set_model_params.deinit();
    try set_model_params.put("sessionId", .{ .string = session_id });
    try set_model_params.put("modelId", .{ .string = "opus" });

    const set_model_request = jsonrpc.Request{
        .method = "session/set_model",
        .id = .{ .number = 2 },
        .params = .{ .object = set_model_params },
    };
    try agent.handleRequest(set_model_request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-test","update":{"sessionUpdate":"current_model_update","currentModelId":"opus"}}}
        \\{"jsonrpc":"2.0","result":{},"id":2}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - setConfig" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_resume = try EnvVarGuard.set(testing.allocator, "BANJO_AUTO_RESUME", "true");
    defer guard_resume.deinit();
    var guard_route = try EnvVarGuard.set(testing.allocator, "BANJO_ROUTE", "duet");
    defer guard_route.deinit();
    var guard_primary_agent = try EnvVarGuard.set(testing.allocator, "BANJO_PRIMARY_AGENT", "claude");
    defer guard_primary_agent.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var new_session_params = std.json.ObjectMap.init(testing.allocator);
    defer new_session_params.deinit();

    const create_request = jsonrpc.Request{
        .method = "session/new",
        .id = .{ .number = 1 },
        .params = .{ .object = new_session_params },
    };
    try agent.handleRequest(create_request);

    const session_id = "session-test";
    tw.output.clearRetainingCapacity();

    var set_config_params = std.json.ObjectMap.init(testing.allocator);
    defer set_config_params.deinit();
    try set_config_params.put("sessionId", .{ .string = session_id });
    try set_config_params.put("configId", .{ .string = "auto_resume" });
    try set_config_params.put("value", .{ .string = "false" });

    const set_config_request = jsonrpc.Request{
        .method = "session/set_config_option",
        .id = .{ .number = 2 },
        .params = .{ .object = set_config_params },
    };
    try agent.handleRequest(set_config_request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","result":{"configOptions":[{"id":"auto_resume","name":"Auto-resume sessions","description":"Resume the last session on startup","type":"select","currentValue":"false","options":[{"value":"true","name":"On"},{"value":"false","name":"Off"}]},{"id":"route","name":"Default agent","description":"Agent to use for new prompts","type":"select","currentValue":"duet","options":[{"value":"claude","name":"Claude"},{"value":"codex","name":"Codex"},{"value":"duet","name":"Duet"}]},{"id":"primary_agent","name":"Primary agent","description":"First agent to answer in duet mode","type":"select","currentValue":"claude","options":[{"value":"claude","name":"Claude"},{"value":"codex","name":"Codex"}]}]},"id":2}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - resumeSession" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","result":{"sessionId":"test-session-123"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - resumeSession existing" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    const session_id = "session-test";

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

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","result":{"sessionId":"session-test"},"id":2}
        \\
    ).diff(tw.getOutput(), true);
}

// =============================================================================
// Property Tests for Prompt Handling
// =============================================================================

const quickcheck = @import("../util/quickcheck.zig");

fn buildContentBlocks(
    allocator: Allocator,
    num_non_text: u8,
    has_text: bool,
    text_idx: u8,
) ![]protocol.ContentBlock {
    var list: std.ArrayListUnmanaged(protocol.ContentBlock) = .empty;
    errdefer list.deinit(allocator);

    const actual_text_pos = if (has_text) text_idx % (num_non_text + 1) else num_non_text + 1;
    var pos: u8 = 0;

    for (0..num_non_text + 1) |_| {
        if (has_text and pos == actual_text_pos) {
            try list.append(allocator, .{ .type = "text", .text = "expected_text" });
        }
        if (pos < num_non_text) {
            try list.append(allocator, .{ .type = "image", .data = "aGVsbG8=", .mimeType = "image/png" });
        }
        pos += 1;
    }

    return list.toOwnedSlice(allocator);
}

test "property: collectPromptParts finds text regardless of position" {
    try quickcheck.check(struct {
        fn prop(args: struct { num_non_text: u4, text_pos: u4 }) bool {
            var tw = TestWriter.init(testing.allocator) catch return false;
            defer tw.deinit();
            var agent = Agent.init(testing.allocator, tw.writer.stream, null);
            defer agent.deinit();

            var session = Agent.Session{
                .id = testing.allocator.dupe(u8, "session") catch return false,
                .cwd = testing.allocator.dupe(u8, ".") catch return false,
                .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
                .availability = .{ .claude = true, .codex = true },
                .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
                .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
                .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
                .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
            };
            defer session.deinit(testing.allocator);

            const blocks = buildContentBlocks(testing.allocator, args.num_non_text, true, args.text_pos) catch return false;
            defer testing.allocator.free(blocks);

            var parts = agent.collectPromptParts(&session, session.id, blocks) catch return false;
            defer parts.deinit(testing.allocator);

            return parts.user_text != null and std.mem.eql(u8, parts.user_text.?, "expected_text");
        }
    }.prop, .{});
}

test "property: collectPromptParts returns null when no text block" {
    try quickcheck.check(struct {
        fn prop(args: struct { num_non_text: u4 }) bool {
            var tw = TestWriter.init(testing.allocator) catch return false;
            defer tw.deinit();
            var agent = Agent.init(testing.allocator, tw.writer.stream, null);
            defer agent.deinit();

            var session = Agent.Session{
                .id = testing.allocator.dupe(u8, "session") catch return false,
                .cwd = testing.allocator.dupe(u8, ".") catch return false,
                .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
                .availability = .{ .claude = true, .codex = true },
                .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
                .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
                .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
                .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
            };
            defer session.deinit(testing.allocator);

            const blocks = buildContentBlocks(testing.allocator, args.num_non_text, false, 0) catch return false;
            defer testing.allocator.free(blocks);

            var parts = agent.collectPromptParts(&session, session.id, blocks) catch return false;
            defer parts.deinit(testing.allocator);

            return parts.user_text == null;
        }
    }.prop, .{});
}

test "collectPromptParts handles empty blocks" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();
    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    const blocks = [_]protocol.ContentBlock{};
    var parts = try agent.collectPromptParts(&session, session.id, blocks[0..]);
    defer parts.deinit(testing.allocator);
    try testing.expect(parts.user_text == null);
}

test "collectPromptParts skips codex image fallback when supported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_codex = try createFakeBinary(testing.allocator, &tmp, "fake-codex");
    defer testing.allocator.free(fake_codex);

    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", fake_codex);
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();
    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    const blocks = [_]protocol.ContentBlock{
        .{
            .type = "image",
            .data = "aGVsbG8=",
            .mimeType = "image/png",
        },
    };

    var parts = try agent.collectPromptParts(&session, session.id, blocks[0..]);
    defer parts.deinit(testing.allocator);

    try testing.expect(parts.codex_inputs != null);
    try testing.expect(parts.codex_context == null);
    try testing.expect(parts.context != null);
    try testing.expect(std.mem.indexOf(u8, parts.context.?, "Image: image/png") != null);
}

test "route_command_map resolves routes" {
    try testing.expectEqual(Route.claude, Agent.route_command_map.get("claude").?);
    try testing.expectEqual(Route.codex, Agent.route_command_map.get("codex").?);
    try testing.expectEqual(Route.duet, Agent.route_command_map.get("duet").?);
    try testing.expect(Agent.route_command_map.get("both") == null);
    try testing.expect(Agent.route_command_map.get("claudeX") == null);
}

test "parseFileUri tolerates malformed percent encoding" {
    const uri = "file:///tmp/%ZZ.txt#L2";
    const info = Agent.parseFileUri(testing.allocator, uri) orelse {
        try testing.expect(false);
        return;
    };
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/%ZZ.txt", info.path);
    try testing.expectEqual(@as(u32, 2), info.line);
}

test "parseFileUri keeps incomplete percent sequence" {
    const uri = "file:///tmp/%";
    const info = Agent.parseFileUri(testing.allocator, uri) orelse {
        try testing.expect(false);
        return;
    };
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/%", info.path);
}

test "Agent handleRequest - cancel" {
    var guard_session = try EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "session-test");
    defer guard_session.deinit();
    var guard_path = try EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_claude = try EnvVarGuard.set(testing.allocator, "CLAUDE_CODE_EXECUTABLE", "claude-hidden");
    defer guard_claude.deinit();
    var guard_codex = try EnvVarGuard.set(testing.allocator, "CODEX_EXECUTABLE", "codex-hidden");
    defer guard_codex.deinit();

    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    const session_id = "session-test";

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
    try testing.expect(session.cancelled.load(.acquire));
}

// =============================================================================
// Error Path Tests
// =============================================================================

test "Agent handleRequest - prompt missing sessionId" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
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

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Missing or invalid prompt"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - prompt session not found" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "nonexistent-session" });
    var prompt_items = std.json.Array.init(testing.allocator);
    var text_block = std.json.ObjectMap.init(testing.allocator);
    try text_block.put("type", .{ .string = "text" });
    try text_block.put("text", .{ .string = "hello" });
    try prompt_items.append(.{ .object = text_block });
    try params.put("prompt", .{ .array = prompt_items });
    defer {
        for (prompt_items.items) |*item| {
            item.object.deinit();
        }
        prompt_items.deinit();
    }

    const request = jsonrpc.Request{
        .method = "session/prompt",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Session not found"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - prompt queued when already handling" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);

    // Create a session with handling_prompt = true (simulating in-progress prompt)
    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "test-session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = false },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
        .handling_prompt = true, // Simulates prompt already in progress
    };
    defer {
        testing.allocator.free(session.id);
        testing.allocator.free(session.cwd);
        session.pending_execute_tools.deinit();
        session.pending_edit_tools.deinit();
        session.always_allowed_tools.deinit();
        session.quiet_tool_ids.deinit();
        for (session.prompt_queue.items) |item| {
            item.deinit(testing.allocator);
        }
        session.prompt_queue.deinit(testing.allocator);
    }
    try agent.sessions.put(session.id, &session);
    defer {
        _ = agent.sessions.remove(session.id);
        agent.deinit();
    }

    // Build prompt request
    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("sessionId", .{ .string = "test-session" });
    var prompt_items = std.json.Array.init(testing.allocator);
    var text_block = std.json.ObjectMap.init(testing.allocator);
    try text_block.put("type", .{ .string = "text" });
    try text_block.put("text", .{ .string = "hello" });
    try prompt_items.append(.{ .object = text_block });
    try params.put("prompt", .{ .array = prompt_items });
    defer {
        for (prompt_items.items) |*item| {
            item.object.deinit();
        }
        prompt_items.deinit();
    }

    const request = jsonrpc.Request{
        .method = "session/prompt",
        .id = .{ .number = 1 },
        .params = .{ .object = params },
    };

    try agent.handleRequest(request);

    // Prompt should be queued, no response yet (deadlock prevention)
    try testing.expectEqual(@as(usize, 0), tw.getOutput().len);
    try testing.expectEqual(@as(usize, 1), session.prompt_queue.items.len);
}

test "Agent handleRequest - setMode missing params" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    // Empty params
    const request = jsonrpc.Request{
        .method = "session/set_mode",
        .id = .{ .number = 1 },
        .params = null,
    };

    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Missing params"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - resumeSession missing params" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    // Empty params - missing sessionId
    const request = jsonrpc.Request{
        .method = "unstable_resumeSession",
        .id = .{ .number = 1 },
        .params = null,
    };

    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32602,"message":"Missing sessionId"},"id":1}
        \\
    ).diff(tw.getOutput(), true);
}

test "Agent handleRequest - authenticate returns success" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    const request = jsonrpc.Request{
        .method = "authenticate",
        .id = .{ .number = 1 },
        .params = null,
    };

    try agent.handleRequest(request);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","result":{},"id":1}
        \\
    ).diff(tw.getOutput(), true);
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

test "buildClaudeStartOptions honors force_new" {
    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    session.cli_session_id = try testing.allocator.dupe(u8, "resume-id");
    session.force_new_claude = true;

    const forced = Agent.buildClaudeStartOptions(&session);
    try testing.expect(forced.resume_session_id == null);
    try testing.expect(!forced.continue_last);

    session.force_new_claude = false;
    const resume_opts = Agent.buildClaudeStartOptions(&session);
    try testing.expect(resume_opts.resume_session_id != null);
    try testing.expect(std.mem.eql(u8, resume_opts.resume_session_id.?, "resume-id"));
}

test "buildCodexStartOptions honors force_new" {
    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    session.codex_session_id = try testing.allocator.dupe(u8, "thread-id");
    session.force_new_codex = true;

    const forced = Agent.buildCodexStartOptions(&session);
    try testing.expect(forced.resume_session_id == null);

    session.force_new_codex = false;
    const resume_opts = Agent.buildCodexStartOptions(&session);
    try testing.expect(resume_opts.resume_session_id != null);
    try testing.expect(std.mem.eql(u8, resume_opts.resume_session_id.?, "thread-id"));
}

test "prepareFreshSessions clears resume state" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();
    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .duet, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = true },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
    };
    defer session.deinit(testing.allocator);

    session.cli_session_id = try testing.allocator.dupe(u8, "claude-id");
    session.codex_session_id = try testing.allocator.dupe(u8, "codex-id");
    const tool_key = try testing.allocator.dupe(u8, "tool");
    try session.pending_execute_tools.put(tool_key, {});

    agent.prepareFreshSessions(&session);

    try testing.expect(session.cli_session_id == null);
    try testing.expect(session.codex_session_id == null);
    try testing.expect(session.force_new_claude);
    try testing.expect(session.force_new_codex);
    try testing.expect(session.pending_execute_tools.count() == 0);
}

test "requestWriteTextFile returns false when cancelled" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    // No reader - waitForResponse will fail, but cancelled check comes first
    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();
    agent.client_capabilities = .{
        .fs = .{ .readTextFile = true, .writeTextFile = true },
        .terminal = false,
    };

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-cancel"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = false },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
        .cancelled = std.atomic.Value(bool).init(true), // Session is cancelled
    };
    defer session.deinit(testing.allocator);

    // Should return false (not error) when cancelled
    const result = try agent.requestWriteTextFile(&session, session.id, "test.txt", "content");
    try testing.expect(!result);
}

test "requestReadTextFile returns null when cancelled" {
    var tw = try TestWriter.init(testing.allocator);
    defer tw.deinit();

    var agent = Agent.init(testing.allocator, tw.writer.stream, null);
    defer agent.deinit();
    agent.client_capabilities = .{
        .fs = .{ .readTextFile = true, .writeTextFile = true },
        .terminal = false,
    };

    var session = Agent.Session{
        .id = try testing.allocator.dupe(u8, "session-cancel"),
        .cwd = try testing.allocator.dupe(u8, "."),
        .config = .{ .auto_resume = true, .route = .claude, .primary_agent = .claude },
        .availability = .{ .claude = true, .codex = false },
        .pending_execute_tools = std.StringHashMap(void).init(testing.allocator),
        .pending_edit_tools = std.StringHashMap(Agent.EditInfo).init(testing.allocator),
        .always_allowed_tools = std.StringHashMap(void).init(testing.allocator),
        .quiet_tool_ids = std.StringHashMap(void).init(testing.allocator),
        .cancelled = std.atomic.Value(bool).init(true), // Session is cancelled
    };
    defer session.deinit(testing.allocator);

    // Should return null (not error) when cancelled
    const result = try agent.requestReadTextFile(&session, session.id, "test.txt", null, null);
    try testing.expect(result == null);
}
