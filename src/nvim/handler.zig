const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const mcp_server_mod = @import("mcp_server.zig");
const mcp_types = @import("mcp_types.zig");
const core_types = @import("../core/types.zig");
const Engine = core_types.Engine;
const callbacks_mod = @import("../core/callbacks.zig");
const EditorCallbacks = callbacks_mod.EditorCallbacks;
const ToolKind = callbacks_mod.ToolKind;
const ToolStatus = callbacks_mod.ToolStatus;
const ApprovalKind = callbacks_mod.ApprovalKind;
const engine_mod = @import("../core/engine.zig");
const claude_bridge = @import("../core/claude_bridge.zig");
const codex_bridge = @import("../core/codex_bridge.zig");

const log = std.log.scoped(.nvim);

pub const Handler = struct {
    allocator: Allocator,
    stdin: std.io.AnyReader,
    stdout: std.io.AnyWriter,
    cwd: []const u8,
    owns_cwd: bool,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    nudge_enabled: bool = true,
    last_nudge_ms: i64 = 0,
    claude_session_id: ?[]const u8 = null,
    codex_session_id: ?[]const u8 = null,
    mcp_server: ?*mcp_server_mod.McpServer = null,
    should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_thread: ?std.Thread = null,

    // State for engine/model/mode selection
    current_engine: Engine = .claude,
    current_model: ?[]const u8 = null,
    permission_mode: protocol.PermissionMode = .default,

    // Session state
    session_active: bool = false,

    // Pending approval request (for Codex)
    pending_approval_id: ?[]const u8 = null,
    pending_approval_response: ?[]const u8 = null,

    // Message queue for decoupling poll thread from processing
    pending_prompt: ?PendingPrompt = null,
    prompt_mutex: std.Thread.Mutex = .{},
    prompt_ready: std.Thread.Condition = .{},

    const PendingPrompt = struct {
        text: []const u8,
        cwd: ?[]const u8,
    };

    pub fn init(allocator: Allocator, stdin: std.io.AnyReader, stdout: std.io.AnyWriter) Handler {
        const cwd_result = std.process.getCwdAlloc(allocator);
        const cwd = cwd_result catch "/";
        const owns_cwd = if (cwd_result) |_| true else |_| false;
        return Handler{
            .allocator = allocator,
            .stdin = stdin,
            .stdout = stdout,
            .cwd = cwd,
            .owns_cwd = owns_cwd,
        };
    }

    pub fn deinit(self: *Handler) void {
        // Signal threads to exit
        self.should_exit.store(true, .release);
        self.prompt_ready.signal(); // Wake main thread if waiting

        // Wait for poll thread
        if (self.poll_thread) |thread| {
            thread.join();
        }

        // Clean up pending prompt if any
        if (self.pending_prompt) |p| {
            self.allocator.free(p.text);
            if (p.cwd) |c| self.allocator.free(c);
        }

        if (self.mcp_server) |mcp| {
            mcp.deinit();
        }
        if (self.claude_session_id) |sid| self.allocator.free(sid);
        if (self.codex_session_id) |sid| self.allocator.free(sid);
        if (self.current_model) |model| self.allocator.free(model);
        if (self.pending_approval_id) |id| self.allocator.free(id);
        if (self.pending_approval_response) |resp| self.allocator.free(resp);
        if (self.owns_cwd) {
            self.allocator.free(self.cwd);
        }
    }

    pub fn run(self: *Handler) !void {
        // Start MCP server for Claude CLI discovery and nvim WebSocket
        self.mcp_server = mcp_server_mod.McpServer.init(self.allocator, self.cwd) catch |err| {
            log.err("Failed to init MCP server: {}", .{err});
            return err;
        };

        if (self.mcp_server) |mcp| {
            // Set up nvim message callback
            mcp.nvim_message_callback = nvimMessageCallback;
            mcp.nvim_callback_ctx = @ptrCast(self);

            mcp.start() catch |err| {
                log.err("Failed to start MCP server: {}", .{err});
            };

            // Send ready notification via stdout (nvim uses this to connect via WebSocket)
            try self.sendStdoutNotification("ready", ReadyNotification{ .mcp_port = mcp.getPort() });
        } else {
            try self.sendStdoutNotification("ready", .{});
        }

        // Spawn poll thread to receive WebSocket messages
        self.poll_thread = std.Thread.spawn(.{}, pollThreadFn, .{self}) catch |err| {
            log.err("Failed to spawn poll thread: {}", .{err});
            return err;
        };

        // Main thread: wait for and process prompts
        while (!self.should_exit.load(.acquire)) {
            // Wait for a prompt to be queued
            self.prompt_mutex.lock();
            while (self.pending_prompt == null and !self.should_exit.load(.acquire)) {
                self.prompt_ready.wait(&self.prompt_mutex);
            }

            // Take the prompt
            const prompt = self.pending_prompt;
            self.pending_prompt = null;
            self.prompt_mutex.unlock();

            // Process it (if we got one and not exiting)
            if (prompt) |p| {
                self.processQueuedPrompt(p);
            }
        }

        // Wait for poll thread to exit
        if (self.poll_thread) |thread| {
            thread.join();
            self.poll_thread = null;
        }
    }

    fn processQueuedPrompt(self: *Handler, prompt: PendingPrompt) void {
        defer {
            self.allocator.free(prompt.text);
            if (prompt.cwd) |c| self.allocator.free(c);
        }

        // Emit session_start if not already in a session
        if (!self.session_active) {
            self.session_active = true;
            self.sendNotification("session_start", protocol.SessionEvent{}) catch {};
            if (self.mcp_server) |mcp| {
                mcp.sendNvimNotification("session_start", protocol.SessionEvent{}) catch {};
            }
        }

        self.cancelled.store(false, .release);

        const req = protocol.PromptRequest{
            .text = prompt.text,
            .cwd = prompt.cwd,
        };

        self.processPrompt(req) catch |err| {
            log.err("Prompt processing error: {}", .{err});
            self.sendError("Processing error") catch {};
        };
    }

    fn pollThreadFn(self: *Handler) void {
        while (!self.should_exit.load(.acquire)) {
            if (self.mcp_server) |mcp| {
                _ = mcp.poll(100) catch |err| {
                    log.warn("MCP poll error: {}", .{err});
                };
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }
    }

    fn nvimMessageCallback(ctx: *anyopaque, method: []const u8, params: ?std.json.Value) void {
        const self: *Handler = @ptrCast(@alignCast(ctx));

        const method_map = std.StaticStringMap(NvimMethod).initComptime(.{
            .{ "prompt", .prompt },
            .{ "cancel", .cancel },
            .{ "nudge_toggle", .nudge_toggle },
            .{ "set_engine", .set_engine },
            .{ "set_model", .set_model },
            .{ "set_permission_mode", .set_permission_mode },
            .{ "get_state", .get_state },
            .{ "approval_response", .approval_response },
            .{ "shutdown", .shutdown },
            .{ "tool_response", .tool_response },
            .{ "selection_changed", .selection_changed },
        });

        const kind = method_map.get(method) orelse {
            log.warn("Unknown nvim method: {s}", .{method});
            return;
        };

        switch (kind) {
            .prompt => self.handleNvimPrompt(params),
            .cancel => self.handleNvimCancel(),
            .nudge_toggle => self.handleNvimNudgeToggle(),
            .set_engine => self.handleNvimSetEngine(params),
            .set_model => self.handleNvimSetModel(params),
            .set_permission_mode => self.handleNvimSetPermissionMode(params),
            .get_state => self.handleNvimGetState(),
            .approval_response => self.handleNvimApprovalResponse(params),
            .shutdown => self.handleNvimShutdown(),
            .tool_response => self.handleNvimToolResponse(params),
            .selection_changed => self.handleNvimSelectionChanged(params),
        }
    }

    const NvimMethod = enum {
        prompt,
        cancel,
        nudge_toggle,
        set_engine,
        set_model,
        set_permission_mode,
        get_state,
        approval_response,
        shutdown,
        tool_response,
        selection_changed,
    };

    fn handleNvimPrompt(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.PromptRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid prompt params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Clone the prompt data since we're queuing it
        const text = self.allocator.dupe(u8, parsed.value.text) catch {
            log.err("Failed to allocate prompt text", .{});
            return;
        };
        const cwd = if (parsed.value.cwd) |c| self.allocator.dupe(u8, c) catch null else null;

        // Queue the prompt and signal main thread
        self.prompt_mutex.lock();
        // If there's already a pending prompt, free it (shouldn't happen normally)
        if (self.pending_prompt) |old| {
            self.allocator.free(old.text);
            if (old.cwd) |c| self.allocator.free(c);
        }
        self.pending_prompt = .{ .text = text, .cwd = cwd };
        self.prompt_mutex.unlock();
        self.prompt_ready.signal();
    }

    fn handleNvimCancel(self: *Handler) void {
        // Emit session_end if session is active
        if (self.session_active) {
            self.session_active = false;
            self.sendNotification("session_end", protocol.SessionEvent{}) catch {};
            // Forward to MCP server
            if (self.mcp_server) |mcp| {
                mcp.sendNvimNotification("session_end", protocol.SessionEvent{}) catch {};
            }
        }

        self.cancelled.store(true, .release);
        self.sendNotification("status", protocol.StatusUpdate{ .text = "Cancelled" }) catch {};
    }

    fn handleNvimNudgeToggle(self: *Handler) void {
        self.nudge_enabled = !self.nudge_enabled;
        const status = if (self.nudge_enabled) "Nudge enabled" else "Nudge disabled";
        self.sendNotification("status", protocol.StatusUpdate{ .text = status }) catch {};
    }

    fn handleNvimSetEngine(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SetEngineRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid set_engine params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const engine_map = std.StaticStringMap(Engine).initComptime(.{
            .{ "claude", .claude },
            .{ "codex", .codex },
        });

        if (engine_map.get(parsed.value.engine)) |engine| {
            self.current_engine = engine;
            self.sendNotification("status", protocol.StatusUpdate{
                .text = if (engine == .claude) "Engine: Claude" else "Engine: Codex",
            }) catch {};
            self.sendStateNotification();
        } else {
            log.warn("Unknown engine: {s}", .{parsed.value.engine});
            self.sendError("Unknown engine") catch {};
        }
    }

    fn handleNvimSetModel(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SetModelRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid set_model params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Validate model name
        const valid_models = [_][]const u8{ "sonnet", "opus", "haiku" };
        var is_valid = false;
        for (valid_models) |m| {
            if (std.mem.eql(u8, parsed.value.model, m)) {
                is_valid = true;
                break;
            }
        }

        if (is_valid) {
            // Free old model if owned
            if (self.current_model) |old| {
                self.allocator.free(old);
            }
            self.current_model = self.allocator.dupe(u8, parsed.value.model) catch null;

            var buf: [64]u8 = undefined;
            const status = std.fmt.bufPrint(&buf, "Model: {s}", .{parsed.value.model}) catch "Model changed";
            self.sendNotification("status", protocol.StatusUpdate{ .text = status }) catch {};
            self.sendStateNotification();
        } else {
            log.warn("Invalid model: {s}", .{parsed.value.model});
            self.sendError("Invalid model (use: sonnet, opus, haiku)") catch {};
        }
    }

    fn handleNvimSetPermissionMode(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SetPermissionModeRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid set_permission_mode params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const mode_map = std.StaticStringMap(protocol.PermissionMode).initComptime(.{
            .{ "default", .default },
            .{ "accept_edits", .accept_edits },
            .{ "auto_approve", .auto_approve },
            .{ "plan_only", .plan_only },
        });

        if (mode_map.get(parsed.value.mode)) |mode| {
            self.permission_mode = mode;
            var buf: [64]u8 = undefined;
            const status = std.fmt.bufPrint(&buf, "Mode: {s}", .{mode.toString()}) catch "Mode changed";
            self.sendNotification("status", protocol.StatusUpdate{ .text = status }) catch {};
            self.sendStateNotification();
        } else {
            log.warn("Unknown mode: {s}", .{parsed.value.mode});
            self.sendError("Unknown mode (use: default, accept_edits, auto_approve, plan_only)") catch {};
        }
    }

    fn handleNvimGetState(self: *Handler) void {
        self.sendStateNotification();
    }

    fn handleNvimApprovalResponse(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.ApprovalResponseRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid approval_response params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Check if this matches the pending approval
        if (self.pending_approval_id) |pending_id| {
            if (std.mem.eql(u8, pending_id, parsed.value.id)) {
                // Store the response
                if (self.pending_approval_response) |old| {
                    self.allocator.free(old);
                }
                self.pending_approval_response = self.allocator.dupe(u8, parsed.value.decision) catch null;
                log.info("Received approval response: {s} for {s}", .{ parsed.value.decision, parsed.value.id });
            } else {
                log.warn("Approval response ID mismatch: expected {s}, got {s}", .{ pending_id, parsed.value.id });
            }
        } else {
            log.warn("Received approval response but no pending approval", .{});
        }
    }

    fn sendStateNotification(self: *Handler) void {
        const engine_str: []const u8 = switch (self.current_engine) {
            .claude => "claude",
            .codex => "codex",
        };

        const session_id = switch (self.current_engine) {
            .claude => self.claude_session_id,
            .codex => self.codex_session_id,
        };

        self.sendNotification("state", protocol.StateResponse{
            .engine = engine_str,
            .model = self.current_model,
            .mode = self.permission_mode.toString(),
            .session_id = session_id,
            .connected = self.mcp_server != null,
        }) catch |err| {
            log.err("Failed to send state notification: {}", .{err});
        };
    }

    fn handleNvimShutdown(self: *Handler) void {
        log.info("Shutdown requested", .{});
        self.should_exit.store(true, .release);
        self.prompt_ready.signal(); // Wake up main thread
    }

    fn handleNvimToolResponse(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(ToolResponseParams, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid tool_response params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        if (self.mcp_server) |mcp| {
            mcp.handleToolResponse(
                parsed.value.correlation_id,
                parsed.value.result,
                parsed.value.@"error",
            ) catch |err| {
                log.warn("Failed to handle tool response: {}", .{err});
            };
        }
    }

    fn handleNvimSelectionChanged(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SelectionInfo, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid selection_changed params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        if (self.mcp_server) |mcp| {
            const range: ?mcp_types.SelectionRange = if (parsed.value.range) |r| .{
                .startLine = r.start_line,
                .startCol = r.start_col,
                .endLine = r.end_line,
                .endCol = r.end_col,
            } else null;

            mcp.updateSelection(.{
                .text = parsed.value.content orelse "",
                .file = parsed.value.file,
                .range = range,
            }) catch |err| {
                log.warn("Failed to update selection cache: {}", .{err});
            };
        }
    }

    fn processPrompt(self: *Handler, prompt_req: protocol.PromptRequest) !void {
        const engine = self.current_engine;

        try self.sendNotification("stream_start", protocol.StreamStart{ .engine = engine });

        var cb_ctx = CallbackContext{ .handler = self };
        const cbs = EditorCallbacks{
            .ctx = @ptrCast(&cb_ctx),
            .vtable = &callback_vtable,
        };

        var prompt_ctx = engine_mod.PromptContext{
            .allocator = self.allocator,
            .session_id = "nvim-session",
            .cwd = if (prompt_req.cwd) |c| c else self.cwd,
            .cancelled = &self.cancelled,
            .nudge = .{
                .enabled = self.nudge_enabled,
                .cooldown_ms = 30_000,
                .last_nudge_ms = &self.last_nudge_ms,
            },
            .cb = cbs,
            .tag_engine = false,
        };

        switch (engine) {
            .claude => {
                var bridge = claude_bridge.Bridge.init(self.allocator, prompt_ctx.cwd);
                defer bridge.deinit();

                bridge.start(.{
                    .permission_mode = self.permission_mode.toCliArg(),
                    .model = self.current_model,
                }) catch |err| {
                    log.err("Failed to start Claude bridge: {}", .{err});
                    try self.sendError("Failed to start Claude");
                    return;
                };

                bridge.sendPrompt(prompt_req.text) catch |err| {
                    log.err("Failed to send prompt: {}", .{err});
                    try self.sendError("Failed to send prompt");
                    return;
                };

                _ = engine_mod.processClaudeMessages(&prompt_ctx, &bridge) catch |err| {
                    log.err("Claude processing error: {}", .{err});
                };
            },
            .codex => {
                var bridge = codex_bridge.CodexBridge.init(self.allocator, prompt_ctx.cwd);
                defer bridge.deinit();

                bridge.start(.{}) catch |err| {
                    log.err("Failed to start Codex bridge: {}", .{err});
                    try self.sendError("Failed to start Codex");
                    return;
                };

                const inputs = [_]codex_bridge.UserInput{
                    .{ .type = "text", .text = prompt_req.text },
                };
                bridge.sendPrompt(&inputs) catch |err| {
                    log.err("Failed to send prompt: {}", .{err});
                    try self.sendError("Failed to send prompt");
                    return;
                };

                _ = engine_mod.processCodexMessages(&prompt_ctx, &bridge) catch |err| {
                    log.err("Codex processing error: {}", .{err});
                };
            },
        }

        try self.sendNotification("stream_end", .{});
    }

    const ReadyNotification = struct {
        mcp_port: u16,
    };

    const ToolResponseParams = struct {
        correlation_id: []const u8,
        result: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
    };

    /// Send notification via WebSocket to nvim client
    fn sendNotification(self: *Handler, method: []const u8, params: anytype) !void {
        const mcp = self.mcp_server orelse return error.NotConnected;
        try mcp.sendNvimNotification(method, params);
    }

    /// Send notification via stdout (used for initial ready message before WebSocket connects)
    fn sendStdoutNotification(self: *Handler, method: []const u8, params: anytype) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };

        const T = @TypeOf(params);
        if (T == @TypeOf(.{})) {
            try jw.write(protocol.JsonRpcNotification{
                .method = method,
                .params = null,
            });
        } else {
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

            try jw.write(protocol.JsonRpcNotification{
                .method = method,
                .params = param_parsed.value,
            });
        }

        try out.writer.writeAll("\n");
        const data = try out.toOwnedSlice();
        defer self.allocator.free(data);
        try self.stdout.writeAll(data);
    }

    fn sendError(self: *Handler, message: []const u8) !void {
        try self.sendNotification("error_msg", protocol.ErrorMessage{ .message = message });
    }

    // Callback implementations
    const CallbackContext = struct {
        handler: *Handler,
    };

    const callback_vtable = EditorCallbacks.VTable{
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
        .onSlashCommands = null,
        .checkAuthRequired = null,
        .sendContinuePrompt = cbSendContinuePrompt,
        .onApprovalRequest = cbOnApprovalRequest,
    };

    fn cbSendText(ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void {
        _ = session_id;
        _ = engine;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text });
    }

    fn cbSendTextRaw(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text });
    }

    fn cbSendTextPrefix(ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_start", protocol.StreamStart{ .engine = engine });
    }

    fn cbSendThought(ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void {
        _ = session_id;
        _ = engine;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text, .is_thought = true });
    }

    fn cbSendThoughtRaw(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text, .is_thought = true });
    }

    fn cbSendThoughtPrefix(ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = ctx;
    }

    // Tools that run silently without UI updates (internal housekeeping)
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

    fn cbSendToolCall(ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_name: []const u8, tool_label: []const u8, tool_id: []const u8, kind: ToolKind, input: ?std.json.Value) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = kind;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));

        // Skip UI updates for quiet tools
        if (quiet_tools.has(tool_name)) {
            return;
        }

        // Stringify input JSON if present
        var input_str: ?[]const u8 = null;
        var input_owned: ?[]const u8 = null;
        defer if (input_owned) |owned| cb_ctx.handler.allocator.free(owned);
        if (input) |inp| {
            var out: std.io.Writer.Allocating = .init(cb_ctx.handler.allocator);
            defer out.deinit();
            var jw: std.json.Stringify = .{ .writer = &out.writer };
            jw.write(inp) catch {};
            input_owned = out.toOwnedSlice() catch null;
            input_str = input_owned;
        }

        try cb_ctx.handler.sendNotification("tool_call", protocol.ToolCall{
            .id = tool_id,
            .name = tool_name,
            .label = tool_label,
            .input = input_str,
        });
    }

    fn cbSendToolResult(ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_id: []const u8, content: ?[]const u8, status: ToolStatus, raw: ?std.json.Value) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = raw;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        const status_str = switch (status) {
            .completed => "completed",
            .failed => "failed",
            .pending => "pending",
            .execute => "pending",
            .approved => "approved",
            .denied => "denied",
        };
        try cb_ctx.handler.sendNotification("tool_result", protocol.ToolResult{
            .id = tool_id,
            .status = status_str,
            .content = content,
        });
    }

    fn cbSendUserMessage(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("status", protocol.StatusUpdate{ .text = text });
    }

    fn cbOnTimeout(ctx: *anyopaque) void {
        // Poll thread handles WebSocket messages independently - nothing needed here
        _ = ctx;
    }

    fn cbOnSessionId(ctx: *anyopaque, engine: Engine, session_id: []const u8) void {
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        cb_ctx.handler.sendNotification("session_id", protocol.SessionIdUpdate{
            .engine = engine,
            .session_id = session_id,
        }) catch |err| {
            log.err("Failed to send session_id notification: {}", .{err});
        };
    }

    fn cbSendContinuePrompt(ctx: *anyopaque, engine: Engine, prompt: []const u8) anyerror!bool {
        _ = ctx;
        _ = engine;
        _ = prompt;
        // For now, don't support nudge continuation - would need to restart bridge
        return false;
    }

    fn cbOnApprovalRequest(ctx: *anyopaque, request_id: std.json.Value, kind: ApprovalKind, params: ?std.json.Value) anyerror!?[]const u8 {
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        const handler = cb_ctx.handler;

        // Convert request_id to string
        var id_buf: [64]u8 = undefined;
        const id_str = switch (request_id) {
            .integer => |i| std.fmt.bufPrint(&id_buf, "{d}", .{i}) catch "unknown",
            .string => |s| s,
            else => "unknown",
        };

        // Store pending approval ID
        if (handler.pending_approval_id) |old| {
            handler.allocator.free(old);
        }
        handler.pending_approval_id = handler.allocator.dupe(u8, id_str) catch return null;
        handler.pending_approval_response = null;

        // Convert kind to risk level
        const risk_level: []const u8 = switch (kind) {
            .command_execution, .exec_command => "high",
            .file_change, .apply_patch => "medium",
        };

        // Convert params to arguments string
        var args_str: ?[]const u8 = null;
        if (params) |p| {
            var out: std.io.Writer.Allocating = .init(handler.allocator);
            defer out.deinit();
            var jw: std.json.Stringify = .{
                .writer = &out.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            jw.write(p) catch {};
            args_str = out.toOwnedSlice() catch null;
        }
        defer if (args_str) |a| handler.allocator.free(a);

        // Get tool name from kind
        const tool_name: []const u8 = switch (kind) {
            .command_execution => "command_execution",
            .exec_command => "exec_command",
            .file_change => "file_change",
            .apply_patch => "apply_patch",
        };

        // Send approval request notification
        handler.sendNotification("approval_request", protocol.ApprovalRequest{
            .id = id_str,
            .tool_name = tool_name,
            .arguments = args_str,
            .risk_level = risk_level,
        }) catch |err| {
            log.err("Failed to send approval_request: {}", .{err});
            return null;
        };

        // Poll for response with 30 second timeout
        const timeout_ms: i64 = 30_000;
        const start_time = std.time.milliTimestamp();

        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            // Check if cancelled
            if (handler.cancelled.load(.acquire)) {
                return "decline";
            }

            // Check if we have a response
            if (handler.pending_approval_response) |response| {
                // Clean up pending state
                if (handler.pending_approval_id) |pid| {
                    handler.allocator.free(pid);
                    handler.pending_approval_id = null;
                }

                // Return owned copy (caller doesn't free, but we need to keep it valid)
                // The response is already allocated, just return it and don't free
                const result = response;
                handler.pending_approval_response = null;
                return result;
            }

            // Poll MCP server for incoming messages
            if (handler.mcp_server) |mcp| {
                _ = mcp.poll(100) catch |err| {
                    log.warn("MCP poll error during approval wait: {}", .{err});
                };
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        // Timeout - clean up and decline
        log.warn("Approval request timed out for {s}", .{id_str});
        if (handler.pending_approval_id) |pid| {
            handler.allocator.free(pid);
            handler.pending_approval_id = null;
        }
        return "decline";
    }
};

test "handler init/deinit" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(!handler.cancelled.load(.acquire));
    try std.testing.expect(handler.nudge_enabled);
}

test "handler nudge toggle" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(handler.nudge_enabled);

    // Toggle nudge (simulate callback)
    handler.nudge_enabled = !handler.nudge_enabled;
    try std.testing.expect(!handler.nudge_enabled);

    // Toggle again
    handler.nudge_enabled = !handler.nudge_enabled;
    try std.testing.expect(handler.nudge_enabled);
}

test "handler cancel" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(!handler.cancelled.load(.acquire));

    // Cancel (simulate callback)
    handler.cancelled.store(true, .release);
    try std.testing.expect(handler.cancelled.load(.acquire));
}

test "cancelled flag is atomic - concurrent reads" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    // Spawn multiple reader threads
    const num_readers = 4;
    var readers: [num_readers]std.Thread = undefined;
    var read_counts: [num_readers]u32 = .{0} ** num_readers;

    for (0..num_readers) |i| {
        readers[i] = try std.Thread.spawn(.{}, struct {
            fn run(h: *Handler, count: *u32) void {
                // Read cancelled flag many times
                var local_count: u32 = 0;
                for (0..10000) |_| {
                    _ = h.cancelled.load(.acquire);
                    local_count += 1;
                }
                count.* = local_count;
            }
        }.run, .{ &handler, &read_counts[i] });
    }

    // Toggle cancelled while readers are running
    for (0..1000) |_| {
        handler.cancelled.store(true, .release);
        handler.cancelled.store(false, .release);
    }

    // Wait for all readers
    for (0..num_readers) |i| {
        readers[i].join();
        try std.testing.expectEqual(@as(u32, 10000), read_counts[i]);
    }
}

test "cancelled flag is atomic - writer thread sets, reader sees it" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    var seen_true = std.atomic.Value(bool).init(false);

    // Reader thread waits for cancelled to become true
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, seen: *std.atomic.Value(bool)) void {
            const start = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - start < 1000) {
                if (h.cancelled.load(.acquire)) {
                    seen.store(true, .release);
                    return;
                }
                std.Thread.yield() catch {};
            }
        }
    }.run, .{ &handler, &seen_true });

    // Small delay then set cancelled
    std.Thread.sleep(10 * std.time.ns_per_ms);
    handler.cancelled.store(true, .release);

    reader.join();

    // Reader should have seen the cancelled flag
    try std.testing.expect(seen_true.load(.acquire));
}

test "should_exit flag stops poll thread" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    // Simulate what run() does - spawn poll thread
    var thread_exited = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, exited: *std.atomic.Value(bool)) void {
            while (!h.should_exit.load(.acquire)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            exited.store(true, .release);
        }
    }.run, .{ &handler, &thread_exited });

    // Verify thread is running
    try std.testing.expect(!thread_exited.load(.acquire));

    // Signal exit
    handler.should_exit.store(true, .release);

    // Wait for thread with timeout
    thread.join();

    // Thread should have exited
    try std.testing.expect(thread_exited.load(.acquire));

    // Now safe to deinit (thread already joined)
    handler.deinit();
}

test "prompt queueing - main thread sees queued prompt" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    // Simulate what handleNvimPrompt does - queue a prompt
    const text = try allocator.dupe(u8, "test prompt");
    handler.prompt_mutex.lock();
    handler.pending_prompt = .{ .text = text, .cwd = null };
    handler.prompt_mutex.unlock();
    handler.prompt_ready.signal();

    // Verify prompt is queued
    handler.prompt_mutex.lock();
    try std.testing.expect(handler.pending_prompt != null);
    try std.testing.expectEqualStrings("test prompt", handler.pending_prompt.?.text);
    handler.prompt_mutex.unlock();

    // Clean up
    handler.should_exit.store(true, .release);
    handler.deinit();
}

test "cancel flag visible across threads during simulated processing" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    var processing_saw_cancel = std.atomic.Value(bool).init(false);
    var processing_started = std.atomic.Value(bool).init(false);

    // Simulate main thread processing a prompt
    const processor = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, started: *std.atomic.Value(bool), saw_cancel: *std.atomic.Value(bool)) void {
            started.store(true, .release);
            // Simulate polling for cancel during processing
            const start = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - start < 1000) {
                if (h.cancelled.load(.acquire)) {
                    saw_cancel.store(true, .release);
                    return;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
    }.run, .{ &handler, &processing_started, &processing_saw_cancel });

    // Wait for processing to start
    while (!processing_started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Simulate poll thread receiving cancel (like handleNvimCancel)
    std.Thread.sleep(50 * std.time.ns_per_ms);
    handler.cancelled.store(true, .release);

    processor.join();

    // Verify processing saw the cancel
    try std.testing.expect(processing_saw_cancel.load(.acquire));

    handler.deinit();
}

test "prompt queue with condition variable wakeup" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    var waiter_got_prompt = std.atomic.Value(bool).init(false);

    // Simulate main thread waiting for prompt
    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, got_prompt: *std.atomic.Value(bool)) void {
            h.prompt_mutex.lock();
            // Wait with timeout
            const start = std.time.milliTimestamp();
            while (h.pending_prompt == null and std.time.milliTimestamp() - start < 1000) {
                h.prompt_ready.timedWait(&h.prompt_mutex, 100 * std.time.ns_per_ms) catch {};
            }
            if (h.pending_prompt != null) {
                got_prompt.store(true, .release);
            }
            h.prompt_mutex.unlock();
        }
    }.run, .{ &handler, &waiter_got_prompt });

    // Small delay then queue prompt
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const text = try allocator.dupe(u8, "queued prompt");
    handler.prompt_mutex.lock();
    handler.pending_prompt = .{ .text = text, .cwd = null };
    handler.prompt_mutex.unlock();
    handler.prompt_ready.signal();

    waiter.join();

    // Verify waiter got the prompt
    try std.testing.expect(waiter_got_prompt.load(.acquire));

    handler.deinit();
}

test "protocol JsonRpcRequest parse" {
    const allocator = std.testing.allocator;

    const input =
        \\{"jsonrpc":"2.0","method":"prompt","params":{"text":"hello"},"id":1}
    ;

    var parsed = try std.json.parseFromSlice(protocol.JsonRpcRequest, allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("prompt", parsed.value.method);
    try std.testing.expect(parsed.value.params != null);
}

test "protocol PromptRequest parse" {
    const allocator = std.testing.allocator;

    const input =
        \\{"text":"hello world","cwd":"/tmp"}
    ;

    var parsed = try std.json.parseFromSlice(protocol.PromptRequest, allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello world", parsed.value.text);
    try std.testing.expect(parsed.value.cwd != null);
    try std.testing.expectEqualStrings("/tmp", parsed.value.cwd.?);
}

test "protocol StreamChunk serialization" {
    const allocator = std.testing.allocator;

    const chunk = protocol.StreamChunk{
        .text = "Hello",
        .is_thought = true,
    };

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(chunk);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"is_thought\":true") != null);
}
