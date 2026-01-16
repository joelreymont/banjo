const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Engine = types.Engine;
const Route = types.Route;
const callbacks = @import("callbacks.zig");
const EditorCallbacks = callbacks.EditorCallbacks;
const ToolKind = callbacks.ToolKind;
const ToolStatus = callbacks.ToolStatus;
const ApprovalKind = callbacks.ApprovalKind;
pub const StopReason = callbacks.EditorCallbacks.StopReason;
const claude_bridge = @import("claude_bridge.zig");
const Bridge = claude_bridge.Bridge;
const codex_bridge = @import("codex_bridge.zig");
const CodexBridge = codex_bridge.CodexBridge;
const CodexMessage = codex_bridge.CodexMessage;
const dots = @import("dots.zig");
const config = @import("config");
const constants = @import("constants.zig");
const auth_markers = @import("auth_markers.zig");

const log = std.log.scoped(.engine);
const debug_log = @import("../util/debug_log.zig");

fn engineDebugLog(comptime fmt: []const u8, args: anytype) void {
    debug_log.write("ENGINE", fmt, args);
}

const prompt_poll_ms: i64 = 250;
pub const NudgeConfig = struct {
    enabled: bool = true,
    cooldown_ms: i64 = constants.nudge_cooldown_ms,
    last_nudge_ms: *i64,
};

/// Inputs for nudge decision - extracted for testability
pub const NudgeInputs = struct {
    enabled: bool,
    cancelled: bool,
    cooldown_ok: bool,
    has_dots: bool,
    reason_ok: bool,
    did_work: bool, // True if >1 tool was used (filters out simple Q&A)

    pub fn shouldNudge(self: NudgeInputs) bool {
        return self.enabled and !self.cancelled and self.cooldown_ok and
            self.has_dots and self.reason_ok and self.did_work;
    }
};

fn authMarkerTextFromTurnError(err: codex_bridge.TurnError) ?[]const u8 {
    if (err.message) |msg| {
        if (auth_markers.containsAuthMarker(msg)) return msg;
    }
    if (err.additional_details) |details| {
        if (auth_markers.containsAuthMarker(details)) return details;
    }
    // Check for unauthorized error info
    if (err.codex_error_info) |info| {
        if (info == .unauthorized) return "unauthorized";
    }
    return null;
}

fn maybeAuthRequired(ctx: *PromptContext, engine: Engine, text: []const u8) !?StopReason {
    if (!auth_markers.containsAuthMarker(text)) return null;
    return try ctx.cb.checkAuthRequired(ctx.session_id, engine, text);
}

pub const PromptContext = struct {
    allocator: Allocator,
    session_id: []const u8,
    cwd: []const u8,
    cancelled: *std.atomic.Value(bool),
    nudge: NudgeConfig,
    cb: EditorCallbacks,

    // For tagging output with engine prefix (duet mode)
    tag_engine: bool = false,

    pub fn isCancelled(self: *const PromptContext) bool {
        return self.cancelled.load(.acquire);
    }
};

fn mapToolKind(tool_name: []const u8) ToolKind {
    const map = std.StaticStringMap(ToolKind).initComptime(.{
        .{ "Read", .read },
        .{ "Glob", .read },
        .{ "Grep", .read },
        .{ "LS", .read },
        .{ "Edit", .edit },
        .{ "Write", .edit },
        .{ "MultiEdit", .edit },
        .{ "NotebookEdit", .edit },
        .{ "Bash", .execute },
        .{ "Task", .execute },
    });
    return map.get(tool_name) orelse .other;
}

fn elapsedMs(start_ms: i64) u64 {
    const now = std.time.milliTimestamp();
    if (now <= start_ms) return 0;
    return @intCast(now - start_ms);
}

fn emitInjectedPrompt(ctx: *PromptContext, prompt: []const u8) void {
    ctx.cb.sendUserMessage(ctx.session_id, prompt) catch |err| {
        log.warn("Failed to emit injected prompt: {}", .{err});
    };
}

const ReloadQueue = struct {
    prompt: ?[]const u8 = null,
    needs_restart: bool = false,

    fn reset(self: *ReloadQueue) void {
        self.prompt = null;
        self.needs_restart = false;
    }

    fn hasPending(self: *const ReloadQueue) bool {
        return self.prompt != null;
    }

    fn schedule(self: *ReloadQueue, engine: Engine) void {
        if (self.hasPending()) return;
        self.prompt = dots.contextPrompt(engine);
        self.needs_restart = true;
    }
};

fn sendQueuedReload(ctx: *PromptContext, engine: Engine, queue: *ReloadQueue) !bool {
    const prompt = queue.prompt orelse return false;
    if (queue.needs_restart) {
        log.info("context reload: restarting {s}", .{engine.label()});
        if (!ctx.cb.restartEngine(engine)) {
            log.err("context reload: restart failed", .{});
            queue.reset();
            return false;
        }
        queue.needs_restart = false;
        log.info("context reload: restart complete", .{});
    }
    log.info("context reload: sending prompt", .{});
    const ok = try ctx.cb.sendContinuePrompt(engine, prompt);
    queue.reset();
    if (!ok) {
        log.err("context reload: prompt rejected", .{});
        return false;
    }
    emitInjectedPrompt(ctx, prompt);
    log.info("context reload: done", .{});
    return true;
}

/// Process Claude Code messages from an active bridge.
/// Caller is responsible for sending the initial prompt and managing bridge lifecycle.
pub fn processClaudeMessages(
    ctx: *PromptContext,
    bridge: *Bridge,
) !StopReason {
    engineDebugLog("processClaudeMessages: entry", .{});
    const start_ms = std.time.milliTimestamp();
    const engine: Engine = .claude;

    var stop_reason: StopReason = .end_turn;
    var first_response_ms: u64 = 0;
    var tool_use_count: u32 = 0; // Track if Claude did actual work
    var msg_count: u32 = 0;
    var stream_prefix_pending = false;
    var thought_prefix_pending = false;
    var timeout_count: u32 = 0;
    var dot_off_tool_id: ?[]const u8 = null;
    defer if (dot_off_tool_id) |id| ctx.allocator.free(id);
    var did_context_reload = false;
    var reload_queue: ReloadQueue = .{};

    while (true) {
        if (ctx.isCancelled()) {
            engineDebugLog("processClaudeMessages: cancelled", .{});
            stop_reason = .cancelled;
            break;
        }

        const deadline_ms = std.time.milliTimestamp() + prompt_poll_ms;
        var msg = bridge.readMessageWithTimeout(deadline_ms) catch |err| {
            if (err == error.Timeout) {
                timeout_count += 1;
                if (timeout_count == 1 or timeout_count % 20 == 0) {
                    engineDebugLog("processClaudeMessages: timeout #{d}", .{timeout_count});
                }
                ctx.cb.onTimeout();
                if (ctx.isCancelled()) {
                    stop_reason = .cancelled;
                    break;
                }
                continue;
            }
            if (err == error.EndOfStream) {
                engineDebugLog("processClaudeMessages: EndOfStream", .{});
                log.info("Claude bridge closed", .{});
                break;
            }
            engineDebugLog("processClaudeMessages: read error", .{});
            log.warn("Claude read error: {}", .{err});
            break;
        } orelse {
            engineDebugLog("processClaudeMessages: null/EOF", .{});
            log.info("Claude bridge returned null (EOF)", .{});
            break;
        };
        defer msg.deinit();

        msg_count += 1;
        timeout_count = 0;
        const msg_time_ms = elapsedMs(start_ms);
        if (first_response_ms == 0) first_response_ms = msg_time_ms;
        engineDebugLog("processClaudeMessages: msg #{d} type={s}", .{ msg_count, @tagName(msg.type) });

        switch (msg.type) {
            .assistant => {
                const has_content = msg.getContent() != null;
                const has_tool_use = msg.getToolUse() != null;
                const has_tool_result = msg.getToolResult() != null;
                engineDebugLog("assistant msg: content={}, tool_use={}, tool_result={}", .{ has_content, has_tool_use, has_tool_result });

                // Process all content blocks in order
                if (msg.getContentBlocksSlice()) |blocks| {
                    for (blocks) |block| {
                        // Handle text blocks
                        if (claude_bridge.StreamMessage.contentBlockToText(block)) |content| {
                            if (first_response_ms == 0) {
                                first_response_ms = msg_time_ms;
                            }
                            engineDebugLog("sending text: {d} bytes", .{content.len});
                            try sendEngineText(ctx, engine, content);
                        }
                        // Handle tool_use blocks
                        if (claude_bridge.StreamMessage.contentBlockToToolUse(block)) |tool| {
                            tool_use_count += 1;
                            engineDebugLog("tool_use: {s}", .{tool.name});
                            try ctx.cb.sendToolCall(
                                ctx.session_id,
                                engine,
                                tool.name,
                                tool.name,
                                tool.id,
                                mapToolKind(tool.name),
                                tool.input,
                            );
                            // Check for dot off command
                            if (std.mem.eql(u8, tool.name, "Bash")) {
                                if (tool.input) |input| {
                                    if (dots.containsDotOff(input)) {
                                        const id_copy = try ctx.allocator.dupe(u8, tool.id);
                                        if (dot_off_tool_id) |old| ctx.allocator.free(old);
                                        dot_off_tool_id = id_copy;
                                    }
                                }
                            }
                        }
                    }
                }

                if (msg.getToolResult()) |tool_result| {
                    const status: ToolStatus = if (tool_result.is_error) .failed else .completed;
                    try ctx.cb.sendToolResult(ctx.session_id, engine, tool_result.id, tool_result.content, status, tool_result.raw);
                    // Check if this is the dot off tool result - only reload on success
                    if (dot_off_tool_id) |id| {
                        if (std.mem.eql(u8, tool_result.id, id)) {
                            ctx.allocator.free(id);
                            dot_off_tool_id = null;
                            if (!tool_result.is_error) {
                                log.info("dot off completed, scheduling context reload", .{});
                                reload_queue.schedule(engine);
                                did_context_reload = true;
                            } else {
                                log.info("dot off failed, skipping context reload", .{});
                            }
                        }
                    }
                }
            },
            .user => {
                if (msg.getToolResult()) |tool_result| {
                    const status: ToolStatus = if (tool_result.is_error) .failed else .completed;
                    try ctx.cb.sendToolResult(ctx.session_id, engine, tool_result.id, tool_result.content, status, tool_result.raw);
                    // Check if this is the dot off tool result - only reload on success
                    if (dot_off_tool_id) |id| {
                        if (std.mem.eql(u8, tool_result.id, id)) {
                            ctx.allocator.free(id);
                            dot_off_tool_id = null;
                            if (!tool_result.is_error) {
                                log.info("dot off completed, scheduling context reload", .{});
                                reload_queue.schedule(engine);
                                did_context_reload = true;
                            } else {
                                log.info("dot off failed, skipping context reload", .{});
                            }
                        }
                    }
                }
            },
            .result => {
                engineDebugLog("result handler entry", .{});
                const stop_reason_opt = msg.getStopReason();
                engineDebugLog("result: stop_reason={?s}", .{stop_reason_opt});
                if (reload_queue.hasPending()) {
                    if (try sendQueuedReload(ctx, engine, &reload_queue)) return .context_reloaded;
                }
                if (stop_reason_opt) |reason| {
                    const now_ms = std.time.milliTimestamp();

                    const nudge_inputs = NudgeInputs{
                        .enabled = ctx.nudge.enabled,
                        .cancelled = ctx.isCancelled(),
                        .cooldown_ok = (now_ms - ctx.nudge.last_nudge_ms.*) >= ctx.nudge.cooldown_ms,
                        .has_dots = dots.hasPendingTasks(ctx.allocator, ctx.cwd).has_tasks,
                        .reason_ok = isNudgeableStopReason(reason),
                        .did_work = tool_use_count > 1,
                    };

                    log.info("Nudge check: cwd={s}, enabled={}, cancelled={}, cooldown_ok={}, has_dots={}, did_work={} (tools={}), reason={s}, reason_ok={}", .{
                        ctx.cwd,
                        nudge_inputs.enabled,
                        nudge_inputs.cancelled,
                        nudge_inputs.cooldown_ok,
                        nudge_inputs.has_dots,
                        nudge_inputs.did_work,
                        tool_use_count,
                        reason,
                        nudge_inputs.reason_ok,
                    });

                    if (nudge_inputs.shouldNudge() and !did_context_reload) {
                        ctx.nudge.last_nudge_ms.* = now_ms;
                        log.info("Claude Code stopped ({s}); pending dots, clearing and triggering", .{reason});
                        reload_queue.schedule(.claude);
                        did_context_reload = true;
                        if (try sendQueuedReload(ctx, .claude, &reload_queue)) return .context_reloaded;
                    } else if (did_context_reload) {
                        log.info("Skipping nudge: already reloaded from dot off", .{});
                    } else if (!nudge_inputs.cooldown_ok) {
                        log.info("Claude Code stopped ({s}); not nudging due to cooldown", .{reason});
                    } else if (!nudge_inputs.did_work) {
                        log.info("Claude Code stopped ({s}); not nudging (no tools used)", .{reason});
                    }
                    stop_reason = mapCliStopReason(reason);
                }
                engineDebugLog("result: breaking out of loop", .{});
                break;
            },
            .stream_event => {
                const event_type = msg.getStreamEventType();
                const has_text = msg.getStreamTextDelta() != null;
                const has_thinking = msg.getStreamThinkingDelta() != null;
                engineDebugLog("stream_event: type={?s}, text={}, thinking={}", .{
                    if (event_type) |et| @tagName(et) else null,
                    has_text,
                    has_thinking,
                });

                if (event_type) |et| {
                    switch (et) {
                        .message_start => {
                            stream_prefix_pending = true;
                            thought_prefix_pending = true;
                        },
                        .message_stop => {
                            stream_prefix_pending = false;
                            thought_prefix_pending = false;
                        },
                        else => {},
                    }
                }
                if (msg.getStreamTextDelta()) |text| {
                    if (first_response_ms == 0) {
                        first_response_ms = msg_time_ms;
                        log.info("First Claude stream response at {d}ms", .{msg_time_ms});
                    }
                    engineDebugLog("stream text delta: {d} bytes", .{text.len});
                    if (stream_prefix_pending and ctx.tag_engine) {
                        try ctx.cb.sendTextRaw(ctx.session_id, engine.prefix());
                        stream_prefix_pending = false;
                    }
                    try ctx.cb.sendTextRaw(ctx.session_id, text);
                }
                if (msg.getStreamThinkingDelta()) |thinking| {
                    if (thought_prefix_pending and ctx.tag_engine) {
                        try ctx.cb.sendThoughtRaw(ctx.session_id, engine.prefix());
                        thought_prefix_pending = false;
                    }
                    try ctx.cb.sendThoughtRaw(ctx.session_id, thinking);
                }
            },
            .system => {
                if (msg.getSystemSubtype()) |subtype| {
                    switch (subtype) {
                        .init => {
                            if (msg.getInitInfo()) |init_info| {
                                if (init_info.slash_commands) |cmds| {
                                    try ctx.cb.onSlashCommands(ctx.session_id, cmds);
                                }
                                if (init_info.session_id) |cli_sid| {
                                    ctx.cb.onSessionId(engine, cli_sid);
                                }
                            }
                            if (msg.getContent()) |content| {
                                if (try ctx.cb.checkAuthRequired(ctx.session_id, engine, content)) |auth_stop| {
                                    stop_reason = auth_stop;
                                    break;
                                }
                            }
                        },
                        .auth_required => {
                            if (msg.getContent()) |content| {
                                if (try ctx.cb.checkAuthRequired(ctx.session_id, engine, content)) |auth_stop| {
                                    stop_reason = auth_stop;
                                    break;
                                }
                            }
                        },
                        .hook_response => {},
                    }
                } else {
                    if (msg.getContent()) |content| {
                        try sendEngineText(ctx, engine, content);
                    }
                }
            },
            else => {},
        }
    }

    const total_ms = elapsedMs(start_ms);
    log.info("Claude prompt complete: {d} msgs, first response at {d}ms, total {d}ms", .{ msg_count, first_response_ms, total_ms });

    return stop_reason;
}

fn sendTaggedContent(
    ctx: *PromptContext,
    engine: Engine,
    text: []const u8,
    comptime buf_size: usize,
    comptime send_fn: fn (EditorCallbacks, []const u8, Engine, []const u8) anyerror!void,
) !void {
    if (ctx.tag_engine) {
        var buf: [buf_size]u8 = undefined;
        const prefix = engine.prefix();
        if (prefix.len + text.len <= buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..][0..text.len], text);
            try send_fn(ctx.cb, ctx.session_id, engine, buf[0 .. prefix.len + text.len]);
        } else {
            const tagged = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, text });
            defer ctx.allocator.free(tagged);
            try send_fn(ctx.cb, ctx.session_id, engine, tagged);
        }
    } else {
        try send_fn(ctx.cb, ctx.session_id, engine, text);
    }
}

fn sendEngineText(ctx: *PromptContext, engine: Engine, text: []const u8) !void {
    return sendTaggedContent(ctx, engine, text, constants.large_buffer_size, EditorCallbacks.sendText);
}

fn mapCliStopReason(cli_reason: []const u8) StopReason {
    const map = std.StaticStringMap(StopReason).initComptime(.{
        .{ "success", .end_turn },
        .{ "cancelled", .cancelled },
        .{ "max_tokens", .max_tokens },
        .{ "error_max_turns", .max_turn_requests },
        .{ "error_max_budget_usd", .max_turn_requests },
    });
    return map.get(cli_reason) orelse .end_turn;
}

fn isNudgeableStopReason(reason: []const u8) bool {
    const nudge_reasons = std.StaticStringMap(void).initComptime(.{
        .{ "error_max_turns", {} },
        .{ "success", {} },
        .{ "end_turn", {} },
    });
    return nudge_reasons.has(reason);
}

fn isCodexMaxTurnError(err: codex_bridge.TurnError) bool {
    return err.isMaxTurnError();
}

fn exitCodeStatus(exit_code: ?i64) ToolStatus {
    const code = exit_code orelse return .completed;
    return if (code == 0) .completed else .failed;
}

fn mapCodexApprovalKind(kind: codex_bridge.CodexMessage.ApprovalKind) ApprovalKind {
    return switch (kind) {
        .command_execution => .command_execution,
        .exec_command => .exec_command,
        .file_change => .file_change,
        .apply_patch => .apply_patch,
    };
}

/// Process Codex CLI messages from an active bridge.
/// Caller is responsible for sending the initial prompt and managing bridge lifecycle.
pub fn processCodexMessages(
    ctx: *PromptContext,
    bridge: *CodexBridge,
) !StopReason {
    const start_ms = std.time.milliTimestamp();
    const engine: Engine = .codex;

    var first_response_ms: u64 = 0;
    var msg_count: u32 = 0;
    var tool_use_count: u32 = 0; // Track if Codex did actual work
    var stream_prefix_pending = false;
    var thought_prefix_pending = false;
    var stop_reason: StopReason = .end_turn;
    var dot_off_tool_id: ?[]const u8 = null;
    defer if (dot_off_tool_id) |id| ctx.allocator.free(id);
    var did_context_reload = false;
    var reload_queue: ReloadQueue = .{};

    while (true) {
        if (ctx.isCancelled()) return .cancelled;

        const deadline_ms = std.time.milliTimestamp() + prompt_poll_ms;
        var msg = bridge.readMessageWithTimeout(deadline_ms) catch |err| {
            if (err == error.Timeout) {
                ctx.cb.onTimeout();
                if (ctx.isCancelled()) return .cancelled;
                continue;
            }
            if (err == error.EndOfStream) {
                log.info("Codex bridge closed", .{});
                break;
            }
            log.warn("Codex read error: {}", .{err});
            break;
        } orelse {
            log.info("Codex bridge returned null (EOF)", .{});
            break;
        };
        defer msg.deinit();

        msg_count += 1;
        const msg_time_ms = elapsedMs(start_ms);
        log.debug("Codex msg #{d} ({s}) at {d}ms", .{ msg_count, @tagName(msg.event_type), msg_time_ms });

        if (msg.event_type == .agent_message_delta) {
            if (msg.text) |text| {
                if (try maybeAuthRequired(ctx, engine, text)) |auth_stop| {
                    stop_reason = auth_stop;
                    break;
                }
                if (first_response_ms == 0) first_response_ms = msg_time_ms;
                if (stream_prefix_pending and ctx.tag_engine) {
                    try ctx.cb.sendTextRaw(ctx.session_id, engine.prefix());
                    stream_prefix_pending = false;
                }
                try ctx.cb.sendTextRaw(ctx.session_id, text);
            }
            continue;
        }

        if (msg.event_type == .reasoning_delta) {
            if (msg.text) |text| {
                if (try maybeAuthRequired(ctx, engine, text)) |auth_stop| {
                    stop_reason = auth_stop;
                    break;
                }
                if (first_response_ms == 0) first_response_ms = msg_time_ms;
                if (thought_prefix_pending and ctx.tag_engine) {
                    try ctx.cb.sendThoughtRaw(ctx.session_id, engine.prefix());
                    thought_prefix_pending = false;
                }
                try ctx.cb.sendThoughtRaw(ctx.session_id, text);
            }
            continue;
        }

        if (msg.event_type == .turn_started) {
            stream_prefix_pending = true;
            thought_prefix_pending = true;
            continue;
        }

        if (msg.getApprovalRequest()) |approval| {
            const cb_kind = mapCodexApprovalKind(approval.kind);
            // Convert RpcRequestId to json.Value for the callback
            const request_id_json: std.json.Value = switch (approval.request_id) {
                .integer => |id| .{ .integer = id },
                .string => |id| .{ .string = id },
            };
            if (try ctx.cb.onApprovalRequest(request_id_json, cb_kind, approval.params)) |decision| {
                bridge.respondApproval(approval.request_id, decision) catch |err| {
                    log.warn("Failed to respond to Codex approval: {}", .{err});
                };
            } else {
                // No callback or callback returned null, auto-decline
                bridge.respondApproval(approval.request_id, "decline") catch |err| {
                    log.warn("Failed to decline Codex approval: {}", .{err});
                };
            }
            continue;
        }

        if (msg.getSessionId()) |sid| {
            ctx.cb.onSessionId(engine, sid);
        }

        if (msg.getToolCall()) |tool| {
            tool_use_count += 1;
            try ctx.cb.sendToolCall(
                ctx.session_id,
                engine,
                "Bash",
                tool.command,
                tool.id,
                .execute,
                null,
            );
            // Check for dot off command
            if (dots.containsDotOffStr(tool.command)) {
                const id_copy = try ctx.allocator.dupe(u8, tool.id);
                if (dot_off_tool_id) |old| ctx.allocator.free(old);
                dot_off_tool_id = id_copy;
            }
            continue;
        }

        if (msg.getToolResult()) |tool_result| {
            const status = exitCodeStatus(tool_result.exit_code);
            try ctx.cb.sendToolResult(ctx.session_id, engine, tool_result.id, tool_result.content, status, tool_result.raw);
            // Check if this is the dot off tool result - only reload on success
            if (dot_off_tool_id) |id| {
                if (std.mem.eql(u8, tool_result.id, id)) {
                    ctx.allocator.free(id);
                    dot_off_tool_id = null;
                    const exit_ok = (tool_result.exit_code orelse 0) == 0;
                    if (exit_ok) {
                        log.info("dot off completed, scheduling context reload", .{});
                        reload_queue.schedule(engine);
                        did_context_reload = true;
                    } else {
                        log.info("dot off failed (exit {?}), skipping context reload", .{tool_result.exit_code});
                    }
                }
            }
            continue;
        }

        if (msg.getThought()) |text| {
            if (try maybeAuthRequired(ctx, engine, text)) |auth_stop| {
                stop_reason = auth_stop;
                break;
            }
            if (first_response_ms == 0) first_response_ms = msg_time_ms;
            try sendEngineThought(ctx, engine, text);
            continue;
        }

        if (msg.getText()) |text| {
            if (try maybeAuthRequired(ctx, engine, text)) |auth_stop| {
                stop_reason = auth_stop;
                break;
            }
            if (first_response_ms == 0) first_response_ms = msg_time_ms;
            try sendEngineText(ctx, engine, text);
            continue;
        }

        // Handle stream_error (non-retryable errors from Codex)
        if (msg.event_type == .stream_error) {
            if (msg.turn_error) |err| {
                if (authMarkerTextFromTurnError(err)) |auth_text| {
                    if (try maybeAuthRequired(ctx, engine, auth_text)) |auth_stop| {
                        stop_reason = auth_stop;
                        break;
                    }
                }
                log.err("Codex stream error: message={?s}", .{err.message});
                // Propagate error to UI - treat as fatal stop
                stop_reason = .end_turn;
                break;
            }
            continue;
        }

        if (msg.event_type == .turn_completed) {
            if (msg.turn_error) |err| {
                if (authMarkerTextFromTurnError(err)) |auth_text| {
                    if (try maybeAuthRequired(ctx, engine, auth_text)) |auth_stop| {
                        stop_reason = auth_stop;
                        break;
                    }
                }
            }

            const has_max_turn_error = if (msg.turn_error) |err| isCodexMaxTurnError(err) else false;
            const has_blocking_error = msg.turn_error != null and !has_max_turn_error;
            const now_ms = std.time.milliTimestamp();

            const nudge_inputs = NudgeInputs{
                .enabled = ctx.nudge.enabled,
                .cancelled = ctx.isCancelled(),
                .cooldown_ok = (now_ms - ctx.nudge.last_nudge_ms.*) >= ctx.nudge.cooldown_ms,
                .has_dots = dots.hasPendingTasks(ctx.allocator, ctx.cwd).has_tasks,
                .reason_ok = !has_blocking_error, // Codex: no blocking error means OK to nudge
                .did_work = tool_use_count > 1,
            };

            const has_pending_reload = reload_queue.hasPending();
            if (has_pending_reload) {
                if (try sendQueuedReload(ctx, engine, &reload_queue)) return .context_reloaded;
            } else if (nudge_inputs.shouldNudge() and !did_context_reload) {
                ctx.nudge.last_nudge_ms.* = now_ms;
                log.info("Codex turn completed; pending dots, clearing and triggering", .{});
                reload_queue.schedule(.codex);
                did_context_reload = true;
                if (try sendQueuedReload(ctx, .codex, &reload_queue)) return .context_reloaded;
            } else if (did_context_reload) {
                log.info("Skipping nudge: already reloaded from dot off", .{});
            } else if (has_blocking_error) {
                log.info("Codex turn completed; not nudging due to error", .{});
            } else if (!nudge_inputs.cooldown_ok) {
                log.info("Codex turn completed; not nudging due to cooldown", .{});
            } else if (!nudge_inputs.did_work) {
                log.info("Codex turn completed; not nudging (no tools used)", .{});
            }
        }

        if (msg.isTurnCompleted()) break;
    }

    const total_ms = elapsedMs(start_ms);
    log.info("Codex prompt complete: {d} msgs, first response at {d}ms, total {d}ms", .{ msg_count, first_response_ms, total_ms });
    return stop_reason;
}

fn sendEngineThought(ctx: *PromptContext, engine: Engine, text: []const u8) !void {
    return sendTaggedContent(ctx, engine, text, constants.small_buffer_size, EditorCallbacks.sendThought);
}

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "maybeAuthRequired invokes callback on auth marker" {
    const AuthCtx = struct {
        called: bool = false,
        last_session_id: ?[]const u8 = null,
        last_engine: ?Engine = null,
        last_content: ?[]const u8 = null,
    };

    const Callbacks = struct {
        fn sendText(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendTextRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendTextPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendThought(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendThoughtRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendThoughtPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendToolCall(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: []const u8, _: []const u8, _: ToolKind, _: ?std.json.Value) anyerror!void {}
        fn sendToolResult(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: ?[]const u8, _: ToolStatus, _: ?std.json.Value) anyerror!void {}
        fn sendUserMessage(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn onTimeout(_: *anyopaque) void {}
        fn onSessionId(_: *anyopaque, _: Engine, _: []const u8) void {}
        fn onSlashCommands(_: *anyopaque, _: []const u8, _: []const []const u8) anyerror!void {}
        fn checkAuthRequired(ctx: *anyopaque, session_id: []const u8, engine: Engine, content: []const u8) anyerror!?StopReason {
            const auth_ctx: *AuthCtx = @ptrCast(@alignCast(ctx));
            auth_ctx.called = true;
            auth_ctx.last_session_id = session_id;
            auth_ctx.last_engine = engine;
            auth_ctx.last_content = content;
            return .auth_required;
        }
        fn sendContinuePrompt(_: *anyopaque, _: Engine, _: []const u8) anyerror!bool {
            return false;
        }
        fn restartEngine(_: *anyopaque, _: Engine) bool {
            return true;
        }
        fn onApprovalRequest(_: *anyopaque, _: std.json.Value, _: ApprovalKind, _: ?std.json.Value) anyerror!?[]const u8 {
            return null;
        }
    };

    const vtable = EditorCallbacks.VTable{
        .sendText = Callbacks.sendText,
        .sendTextRaw = Callbacks.sendTextRaw,
        .sendTextPrefix = Callbacks.sendTextPrefix,
        .sendThought = Callbacks.sendThought,
        .sendThoughtRaw = Callbacks.sendThoughtRaw,
        .sendThoughtPrefix = Callbacks.sendThoughtPrefix,
        .sendToolCall = Callbacks.sendToolCall,
        .sendToolResult = Callbacks.sendToolResult,
        .sendUserMessage = Callbacks.sendUserMessage,
        .onTimeout = Callbacks.onTimeout,
        .onSessionId = Callbacks.onSessionId,
        .onSlashCommands = Callbacks.onSlashCommands,
        .checkAuthRequired = Callbacks.checkAuthRequired,
        .sendContinuePrompt = Callbacks.sendContinuePrompt,
        .restartEngine = Callbacks.restartEngine,
        .onApprovalRequest = Callbacks.onApprovalRequest,
    };

    var auth_ctx = AuthCtx{};
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&auth_ctx), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "session",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
        .tag_engine = false,
    };

    const stop = try maybeAuthRequired(&ctx, .claude, "Please login to continue.");
    const summary = .{
        .stop = if (stop) |s| @tagName(s) else null,
        .called = auth_ctx.called,
        .session_id = auth_ctx.last_session_id,
        .engine = if (auth_ctx.last_engine) |eng| @tagName(eng) else null,
        .content = auth_ctx.last_content,
    };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.maybeAuthRequired invokes callback on auth marker__struct_<^\d+$>
        \\  .stop: ?[:0]const u8
        \\    "auth_required"
        \\  .called: bool = true
        \\  .session_id: ?[]const u8
        \\    "session"
        \\  .engine: ?[:0]const u8
        \\    "claude"
        \\  .content: ?[]const u8
        \\    "Please login to continue."
    ).expectEqual(summary);
}

test "maybeAuthRequired ignores non-auth text" {
    const AuthCtx = struct { called: bool = false };
    const Callbacks = struct {
        fn sendText(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendTextRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendTextPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendThought(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendThoughtRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendThoughtPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendToolCall(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: []const u8, _: []const u8, _: ToolKind, _: ?std.json.Value) anyerror!void {}
        fn sendToolResult(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: ?[]const u8, _: ToolStatus, _: ?std.json.Value) anyerror!void {}
        fn sendUserMessage(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn onTimeout(_: *anyopaque) void {}
        fn onSessionId(_: *anyopaque, _: Engine, _: []const u8) void {}
        fn onSlashCommands(_: *anyopaque, _: []const u8, _: []const []const u8) anyerror!void {}
        fn checkAuthRequired(ctx: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!?StopReason {
            const auth_ctx: *AuthCtx = @ptrCast(@alignCast(ctx));
            auth_ctx.called = true;
            return .auth_required;
        }
        fn sendContinuePrompt(_: *anyopaque, _: Engine, _: []const u8) anyerror!bool {
            return false;
        }
        fn restartEngine(_: *anyopaque, _: Engine) bool {
            return true;
        }
        fn onApprovalRequest(_: *anyopaque, _: std.json.Value, _: ApprovalKind, _: ?std.json.Value) anyerror!?[]const u8 {
            return null;
        }
    };

    const vtable = EditorCallbacks.VTable{
        .sendText = Callbacks.sendText,
        .sendTextRaw = Callbacks.sendTextRaw,
        .sendTextPrefix = Callbacks.sendTextPrefix,
        .sendThought = Callbacks.sendThought,
        .sendThoughtRaw = Callbacks.sendThoughtRaw,
        .sendThoughtPrefix = Callbacks.sendThoughtPrefix,
        .sendToolCall = Callbacks.sendToolCall,
        .sendToolResult = Callbacks.sendToolResult,
        .sendUserMessage = Callbacks.sendUserMessage,
        .onTimeout = Callbacks.onTimeout,
        .onSessionId = Callbacks.onSessionId,
        .onSlashCommands = Callbacks.onSlashCommands,
        .checkAuthRequired = Callbacks.checkAuthRequired,
        .sendContinuePrompt = Callbacks.sendContinuePrompt,
        .restartEngine = Callbacks.restartEngine,
        .onApprovalRequest = Callbacks.onApprovalRequest,
    };

    var auth_ctx = AuthCtx{};
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&auth_ctx), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "session",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
        .tag_engine = false,
    };

    const stop = try maybeAuthRequired(&ctx, .claude, "All good.");
    const summary = .{ .stop = if (stop) |s| @tagName(s) else null, .called = auth_ctx.called };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.maybeAuthRequired ignores non-auth text__struct_<^\d+$>
        \\  .stop: ?[:0]const u8
        \\    null
        \\  .called: bool = false
    ).expectEqual(summary);
}

test "authMarkerTextFromTurnError finds auth marker" {
    const err = codex_bridge.TurnError{ .message = "Please login to continue." };
    const found = authMarkerTextFromTurnError(err);
    const summary = .{ .text = found };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.authMarkerTextFromTurnError finds auth marker__struct_<^\d+$>
        \\  .text: ?[]const u8
        \\    "Please login to continue."
    ).expectEqual(summary);
}

test "authMarkerTextFromTurnError returns null when missing" {
    const err = codex_bridge.TurnError{ .message = "No issues here." };
    const summary = .{ .text = authMarkerTextFromTurnError(err) };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.authMarkerTextFromTurnError returns null when missing__struct_<^\d+$>
        \\  .text: ?[]const u8
        \\    null
    ).expectEqual(summary);
}

test "PromptContext.isCancelled reads atomic flag" {
    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;

    const ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{
            .enabled = false,
            .cooldown_ms = 0,
            .last_nudge_ms = &last_nudge,
        },
        .cb = undefined,
    };

    const initial = ctx.isCancelled();
    cancelled.store(true, .release);
    const after_true = ctx.isCancelled();
    cancelled.store(false, .release);
    const after_false = ctx.isCancelled();
    const summary = .{ .initial = initial, .after_true = after_true, .after_false = after_false };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.PromptContext.isCancelled reads atomic flag__struct_<^\d+$>
        \\  .initial: bool = false
        \\  .after_true: bool = true
        \\  .after_false: bool = false
    ).expectEqual(summary);
}

test "mapCliStopReason maps cancelled" {
    const summary = .{
        .cancelled = mapCliStopReason("cancelled"),
        .success = mapCliStopReason("success"),
        .unknown = mapCliStopReason("unknown"),
    };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.mapCliStopReason maps cancelled__struct_<^\d+$>
        \\  .cancelled: core.callbacks.EditorCallbacks.StopReason
        \\    .cancelled
        \\  .success: core.callbacks.EditorCallbacks.StopReason
        \\    .end_turn
        \\  .unknown: core.callbacks.EditorCallbacks.StopReason
        \\    .end_turn
    ).expectEqual(summary);
}

test "PromptContext.isCancelled sees updates from another thread" {
    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;

    const ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{
            .enabled = false,
            .cooldown_ms = 0,
            .last_nudge_ms = &last_nudge,
        },
        .cb = undefined,
    };

    var seen_cancelled = std.atomic.Value(bool).init(false);

    // Reader thread polls isCancelled
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(c: *const PromptContext, seen: *std.atomic.Value(bool)) void {
            const start = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - start < 1000) {
                if (c.isCancelled()) {
                    seen.store(true, .release);
                    return;
                }
                std.Thread.yield() catch |err| {
                    log.warn("Thread yield failed: {}", .{err});
                };
            }
        }
    }.run, .{ &ctx, &seen_cancelled });

    // Writer thread sets cancelled after delay
    std.Thread.sleep(10 * std.time.ns_per_ms);
    cancelled.store(true, .release);

    reader.join();

    const summary = .{ .seen = seen_cancelled.load(.acquire) };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.PromptContext.isCancelled sees updates from another thread__struct_<^\d+$>
        \\  .seen: bool = true
    ).expectEqual(summary);
}

test "PromptContext.isCancelled concurrent access is safe" {
    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;

    const ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{
            .enabled = false,
            .cooldown_ms = 0,
            .last_nudge_ms = &last_nudge,
        },
        .cb = undefined,
    };

    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;
    var read_counts: [num_threads]std.atomic.Value(u32) = .{std.atomic.Value(u32).init(0)} ** num_threads;

    // Spawn reader threads
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(c: *const PromptContext, count: *std.atomic.Value(u32)) void {
                var local: u32 = 0;
                for (0..10000) |_| {
                    _ = c.isCancelled();
                    local += 1;
                }
                count.store(local, .release);
            }
        }.run, .{ &ctx, &read_counts[i] });
    }

    // Writer toggles cancelled while readers run
    for (0..1000) |_| {
        cancelled.store(true, .release);
        cancelled.store(false, .release);
    }

    // Wait for readers
    for (0..num_threads) |i| {
        threads[i].join();
    }
    const summary = .{
        .counts = [_]u32{
            read_counts[0].load(.acquire),
            read_counts[1].load(.acquire),
            read_counts[2].load(.acquire),
            read_counts[3].load(.acquire),
        },
    };
    try (ohsnap{}).snap(@src(),
        \\core.engine.test.PromptContext.isCancelled concurrent access is safe__struct_<^\d+$>
        \\  .counts: [4]u32
        \\    [0]: u32 = 10000
        \\    [1]: u32 = 10000
        \\    [2]: u32 = 10000
        \\    [3]: u32 = 10000
    ).expectEqual(summary);
}

test "integration: processClaudeMessages nudge requires tool use" {
    // Integration test: inject real StreamMessages into Bridge, verify nudge behavior
    // Regression: previously nudged after every completion even without tool use

    const NudgeTracker = struct {
        nudge_called: bool = false,
        allocator: Allocator,

        fn sendContinuePrompt(ctx: *anyopaque, _: Engine, _: []const u8) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.nudge_called = true;
            return true;
        }
        fn restartEngine(_: *anyopaque, _: Engine) bool {
            return true;
        }
    };

    const Callbacks = struct {
        fn sendText(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendTextRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendTextPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendThought(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendThoughtRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendThoughtPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendToolCall(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: []const u8, _: []const u8, _: ToolKind, _: ?std.json.Value) anyerror!void {}
        fn sendToolResult(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: ?[]const u8, _: ToolStatus, _: ?std.json.Value) anyerror!void {}
        fn sendUserMessage(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn onTimeout(_: *anyopaque) void {}
        fn onSessionId(_: *anyopaque, _: Engine, _: []const u8) void {}
        fn onSlashCommands(_: *anyopaque, _: []const u8, _: []const []const u8) anyerror!void {}
        fn checkAuthRequired(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!?StopReason {
            return null;
        }
        fn onApprovalRequest(_: *anyopaque, _: std.json.Value, _: ApprovalKind, _: ?std.json.Value) anyerror!?[]const u8 {
            return null;
        }
    };

    // Test case 1: Q&A response (no tools) - should NOT nudge
    {
        var tracker = NudgeTracker{ .allocator = testing.allocator };
        const vtable = EditorCallbacks.VTable{
            .sendText = Callbacks.sendText,
            .sendTextRaw = Callbacks.sendTextRaw,
            .sendTextPrefix = Callbacks.sendTextPrefix,
            .sendThought = Callbacks.sendThought,
            .sendThoughtRaw = Callbacks.sendThoughtRaw,
            .sendThoughtPrefix = Callbacks.sendThoughtPrefix,
            .sendToolCall = Callbacks.sendToolCall,
            .sendToolResult = Callbacks.sendToolResult,
            .sendUserMessage = Callbacks.sendUserMessage,
            .onTimeout = Callbacks.onTimeout,
            .onSessionId = Callbacks.onSessionId,
            .onSlashCommands = Callbacks.onSlashCommands,
            .checkAuthRequired = Callbacks.checkAuthRequired,
            .sendContinuePrompt = NudgeTracker.sendContinuePrompt,
            .restartEngine = NudgeTracker.restartEngine,
            .onApprovalRequest = Callbacks.onApprovalRequest,
        };
        const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

        var cancelled = std.atomic.Value(bool).init(false);
        var last_nudge: i64 = 0;
        var ctx = PromptContext{
            .allocator = testing.allocator,
            .session_id = "test",
            .cwd = "/tmp", // No dots here
            .cancelled = &cancelled,
            .nudge = .{ .enabled = true, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
            .cb = cbs,
        };

        // Create bridge and inject Q&A messages (text only, no tool_use)
        var bridge = Bridge.init(testing.allocator, "/tmp");
        defer bridge.deinit();
        bridge.reader_closed = true; // Signal no more messages after queue

        // Parse and inject: assistant text message
        const text_json = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hello!\"}]}}";
        var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
        const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), text_json, .{});
        bridge.queue_mutex.lock();
        try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
            .type = .assistant,
            .subtype = null,
            .raw = parsed1.value,
            .arena = arena1,
        });
        bridge.queue_mutex.unlock();

        // Parse and inject: result message
        const result_json = "{\"type\":\"result\",\"result\":{\"stop_reason\":\"success\"}}";
        var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
        const parsed2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
        bridge.queue_mutex.lock();
        try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
            .type = .result,
            .subtype = null,
            .raw = parsed2.value,
            .arena = arena2,
        });
        bridge.queue_mutex.unlock();

        // Process messages
        _ = try processClaudeMessages(&ctx, &bridge);

        // Should NOT have nudged (no tools used)
        try testing.expect(!tracker.nudge_called);
    }

    // Test case 2: Work response (with tool_use) - verify tool tracking works
    // Note: actual nudge requires pending dots which we can't easily mock,
    // but we verify the tool_use path is exercised by checking no crash
    {
        var tracker = NudgeTracker{ .allocator = testing.allocator };
        const vtable = EditorCallbacks.VTable{
            .sendText = Callbacks.sendText,
            .sendTextRaw = Callbacks.sendTextRaw,
            .sendTextPrefix = Callbacks.sendTextPrefix,
            .sendThought = Callbacks.sendThought,
            .sendThoughtRaw = Callbacks.sendThoughtRaw,
            .sendThoughtPrefix = Callbacks.sendThoughtPrefix,
            .sendToolCall = Callbacks.sendToolCall,
            .sendToolResult = Callbacks.sendToolResult,
            .sendUserMessage = Callbacks.sendUserMessage,
            .onTimeout = Callbacks.onTimeout,
            .onSessionId = Callbacks.onSessionId,
            .onSlashCommands = Callbacks.onSlashCommands,
            .checkAuthRequired = Callbacks.checkAuthRequired,
            .sendContinuePrompt = NudgeTracker.sendContinuePrompt,
            .restartEngine = NudgeTracker.restartEngine,
            .onApprovalRequest = Callbacks.onApprovalRequest,
        };
        const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

        var cancelled = std.atomic.Value(bool).init(false);
        var last_nudge: i64 = 0;
        var ctx = PromptContext{
            .allocator = testing.allocator,
            .session_id = "test",
            .cwd = "/tmp",
            .cancelled = &cancelled,
            .nudge = .{ .enabled = true, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
            .cb = cbs,
        };

        var bridge = Bridge.init(testing.allocator, "/tmp");
        defer bridge.deinit();
        bridge.reader_closed = true;

        // Parse and inject: assistant message with tool_use
        const tool_json = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Read\",\"input\":{}}]}}";
        var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
        const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
        bridge.queue_mutex.lock();
        try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
            .type = .assistant,
            .subtype = null,
            .raw = parsed1.value,
            .arena = arena1,
        });
        bridge.queue_mutex.unlock();

        // Parse and inject: result message
        const result_json = "{\"type\":\"result\",\"result\":{\"stop_reason\":\"success\"}}";
        var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
        const parsed2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
        bridge.queue_mutex.lock();
        try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
            .type = .result,
            .subtype = null,
            .raw = parsed2.value,
            .arena = arena2,
        });
        bridge.queue_mutex.unlock();

        // Process messages - tool path exercised, nudge not called because no dots in /tmp
        _ = try processClaudeMessages(&ctx, &bridge);

        // Still no nudge because /tmp has no dots (dots.hasPendingTasks returns false)
        // But the key is: if there WERE dots, it would nudge because tool_use_count > 1
        try testing.expect(!tracker.nudge_called);
    }
}

test "NudgeInputs shouldNudge logic" {
    // Test all combinations of NudgeInputs to verify shouldNudge behavior
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // All true - should nudge
    const all_true = NudgeInputs{
        .enabled = true,
        .cancelled = false,
        .cooldown_ok = true,
        .has_dots = true,
        .reason_ok = true,
        .did_work = true,
    };

    // Disabled - should not nudge
    const disabled = NudgeInputs{
        .enabled = false,
        .cancelled = false,
        .cooldown_ok = true,
        .has_dots = true,
        .reason_ok = true,
        .did_work = true,
    };

    // Cancelled - should not nudge
    const cancelled = NudgeInputs{
        .enabled = true,
        .cancelled = true,
        .cooldown_ok = true,
        .has_dots = true,
        .reason_ok = true,
        .did_work = true,
    };

    // No dots - should not nudge
    const no_dots = NudgeInputs{
        .enabled = true,
        .cancelled = false,
        .cooldown_ok = true,
        .has_dots = false,
        .reason_ok = true,
        .did_work = true,
    };

    // No work done - should not nudge
    const no_work = NudgeInputs{
        .enabled = true,
        .cancelled = false,
        .cooldown_ok = true,
        .has_dots = true,
        .reason_ok = true,
        .did_work = false,
    };

    // Cooldown not ok - should not nudge
    const cooldown = NudgeInputs{
        .enabled = true,
        .cancelled = false,
        .cooldown_ok = false,
        .has_dots = true,
        .reason_ok = true,
        .did_work = true,
    };

    try out.writer.print(
        \\all_true: {any}
        \\disabled: {any}
        \\cancelled: {any}
        \\no_dots: {any}
        \\no_work: {any}
        \\cooldown: {any}
        \\
    , .{
        all_true.shouldNudge(),
        disabled.shouldNudge(),
        cancelled.shouldNudge(),
        no_dots.shouldNudge(),
        no_work.shouldNudge(),
        cooldown.shouldNudge(),
    });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\all_true: true
        \\disabled: false
        \\cancelled: false
        \\no_dots: false
        \\no_work: false
        \\cooldown: false
        \\
    ).diff(snapshot, true);
}

test "dots trigger and clear commands snapshot" {
    // Verify the trigger and clear commands used in nudge
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try out.writer.print(
        \\claude_trigger: {s}
        \\claude_clear: {s}
        \\codex_trigger: {s}
        \\codex_clear: {s}
        \\
    , .{
        dots.trigger(.claude),
        dots.clearCmd(.claude),
        dots.trigger(.codex),
        dots.clearCmd(.codex),
    });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude_trigger: /dot
        \\claude_clear: /clear
        \\codex_trigger: $dot
        \\codex_clear: /clear
        \\
    ).diff(snapshot, true);
}

test "isNudgeableStopReason categorizes stop reasons" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try out.writer.print(
        \\success: {any}
        \\end_turn: {any}
        \\error_max_turns: {any}
        \\cancelled: {any}
        \\unknown: {any}
        \\
    , .{
        isNudgeableStopReason("success"),
        isNudgeableStopReason("end_turn"),
        isNudgeableStopReason("error_max_turns"),
        isNudgeableStopReason("cancelled"),
        isNudgeableStopReason("unknown"),
    });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\success: true
        \\end_turn: true
        \\error_max_turns: true
        \\cancelled: false
        \\unknown: false
        \\
    ).diff(snapshot, true);
}

// Reusable test fixture for context reload verification
const ContextReloadTracker = struct {
    prompts: std.ArrayListUnmanaged([]const u8) = .empty,
    user_msgs: std.ArrayListUnmanaged([]const u8) = .empty,
    restart_count: usize = 0,
    allocator: Allocator,

    fn init(allocator: Allocator) ContextReloadTracker {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ContextReloadTracker) void {
        for (self.prompts.items) |p| self.allocator.free(p);
        self.prompts.deinit(self.allocator);
        for (self.user_msgs.items) |p| self.allocator.free(p);
        self.user_msgs.deinit(self.allocator);
    }

    fn sendContinuePrompt(ctx: *anyopaque, _: Engine, prompt: []const u8) anyerror!bool {
        const self: *ContextReloadTracker = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, prompt);
        try self.prompts.append(self.allocator, copy);
        return true;
    }

    fn restartEngine(ctx: *anyopaque, _: Engine) bool {
        const self: *ContextReloadTracker = @ptrCast(@alignCast(ctx));
        self.restart_count += 1;
        return true;
    }

    fn sendUserMessage(ctx: *anyopaque, _: []const u8, text: []const u8) anyerror!void {
        const self: *ContextReloadTracker = @ptrCast(@alignCast(ctx));
        const copy = try self.allocator.dupe(u8, text);
        try self.user_msgs.append(self.allocator, copy);
    }

    fn hasContextReload(self: *const ContextReloadTracker) bool {
        if (self.restart_count == 0) return false;
        for (self.prompts.items) |p| {
            if (std.mem.indexOf(u8, p, "AGENTS.md") != null) return true;
        }
        return false;
    }
};

fn queueClaudeResult(allocator: Allocator, bridge: *Bridge, reason: []const u8) !void {
    var buf: [96]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{{\"type\":\"result\",\"subtype\":\"{s}\"}}", .{reason});
    var arena = std.heap.ArenaAllocator.init(allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(allocator, claude_bridge.StreamMessage{
        .type = .result,
        .subtype = reason,
        .raw = parsed.value,
        .arena = arena,
    });
    bridge.queue_mutex.unlock();
}

fn queueCodexTurn(allocator: Allocator, bridge: *CodexBridge) !void {
    const arena = std.heap.ArenaAllocator.init(allocator);
    bridge.queue_mutex.lock();
    try bridge.pending_messages.append(allocator, codex_bridge.CodexMessage{
        .event_type = .turn_completed,
        .turn_status = "completed",
        .arena = arena,
    });
    bridge.queue_mutex.unlock();
}

fn createTestCallbacks(comptime T: type) EditorCallbacks.VTable {
    const Callbacks = struct {
        fn sendText(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendTextRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendTextPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendThought(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!void {}
        fn sendThoughtRaw(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn sendThoughtPrefix(_: *anyopaque, _: []const u8, _: Engine) anyerror!void {}
        fn sendToolCall(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: []const u8, _: []const u8, _: ToolKind, _: ?std.json.Value) anyerror!void {}
        fn sendToolResult(_: *anyopaque, _: []const u8, _: Engine, _: []const u8, _: ?[]const u8, _: ToolStatus, _: ?std.json.Value) anyerror!void {}
        fn sendUserMessage(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
            return T.sendUserMessage(ctx, session_id, text);
        }
        fn onTimeout(_: *anyopaque) void {}
        fn onSessionId(_: *anyopaque, _: Engine, _: []const u8) void {}
        fn onSlashCommands(_: *anyopaque, _: []const u8, _: []const []const u8) anyerror!void {}
        fn checkAuthRequired(_: *anyopaque, _: []const u8, _: Engine, _: []const u8) anyerror!?StopReason {
            return null;
        }
        fn onApprovalRequest(_: *anyopaque, _: std.json.Value, _: ApprovalKind, _: ?std.json.Value) anyerror!?[]const u8 {
            return null;
        }
    };
    return .{
        .sendText = Callbacks.sendText,
        .sendTextRaw = Callbacks.sendTextRaw,
        .sendTextPrefix = Callbacks.sendTextPrefix,
        .sendThought = Callbacks.sendThought,
        .sendThoughtRaw = Callbacks.sendThoughtRaw,
        .sendThoughtPrefix = Callbacks.sendThoughtPrefix,
        .sendToolCall = Callbacks.sendToolCall,
        .sendToolResult = Callbacks.sendToolResult,
        .sendUserMessage = Callbacks.sendUserMessage,
        .onTimeout = Callbacks.onTimeout,
        .onSessionId = Callbacks.onSessionId,
        .onSlashCommands = Callbacks.onSlashCommands,
        .checkAuthRequired = Callbacks.checkAuthRequired,
        .sendContinuePrompt = T.sendContinuePrompt,
        .restartEngine = T.restartEngine,
        .onApprovalRequest = Callbacks.onApprovalRequest,
    };
}

test "integration: dot off triggers context reload" {
    // Test that a Bash tool_use with "dot off" followed by tool_result triggers context reload
    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-dot-off",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = Bridge.init(testing.allocator, "/tmp");
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: Bash tool_use with "dot off abc123"
    const tool_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"dot off abc123 -r done"}}]}}
    ;
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed1.value,
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    // Inject: tool_result for the same tool ID
    const result_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"Dot closed"}]}}
    ;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed2.value,
        .arena = arena2,
    });
    bridge.queue_mutex.unlock();

    try queueClaudeResult(testing.allocator, &bridge, "end_turn");
    try queueClaudeResult(testing.allocator, &bridge, "success");

    _ = try processClaudeMessages(&ctx, &bridge);

    // Verify context reload was triggered (clear + context_prompt)
    try testing.expect(tracker.hasContextReload());
}

test "integration: dot off failure skips context reload" {
    // Test that a failed "dot off" (is_error=true) does NOT trigger context reload
    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-dot-off-fail",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = Bridge.init(testing.allocator, "/tmp");
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: Bash tool_use with "dot off abc123"
    const tool_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"dot off abc123 -r done"}}]}}
    ;
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed1.value,
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    // Inject: tool_result with is_error=true (command failed)
    const result_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"Error: dot not found","is_error":true}]}}
    ;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed2.value,
        .arena = arena2,
    });
    bridge.queue_mutex.unlock();

    try queueClaudeResult(testing.allocator, &bridge, "end_turn");

    _ = try processClaudeMessages(&ctx, &bridge);

    // Verify context reload was NOT triggered (no prompts sent)
    try testing.expect(!tracker.hasContextReload());
}

test "integration: dot off skips subsequent nudge" {
    // Test that did_context_reload flag prevents double reload on nudge
    const CountingTracker = struct {
        reload_count: u32 = 0,
        allocator: Allocator,

        fn sendContinuePrompt(_: *anyopaque, _: Engine, _: []const u8) anyerror!bool {
            return true;
        }

        fn restartEngine(ctx_ptr: *anyopaque, _: Engine) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.reload_count += 1;
            return true;
        }

        fn sendUserMessage(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
    };

    var tracker = CountingTracker{ .allocator = testing.allocator };
    const vtable = createTestCallbacks(CountingTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;

    // Use a temp dir with a .dots directory to enable nudge
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(".dots");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-no-double",
        .cwd = tmp_path,
        .cancelled = &cancelled,
        .nudge = .{ .enabled = true, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = Bridge.init(testing.allocator, tmp_path);
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: Bash tool_use with "dot off"
    const tool_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-2","name":"Bash","input":{"command":"dot off xyz"}}]}}
    ;
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed1.value,
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    // Inject: tool_result
    const result_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tool-2","content":"Done"}]}}
    ;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed2.value,
        .arena = arena2,
    });
    bridge.queue_mutex.unlock();

    try queueClaudeResult(testing.allocator, &bridge, "success");
    try queueClaudeResult(testing.allocator, &bridge, "success");

    _ = try processClaudeMessages(&ctx, &bridge);

    // Should only reload once (from dot off), not twice (dot off + nudge)
    // The did_context_reload flag prevents double reload
    try testing.expectEqual(@as(u32, 1), tracker.reload_count);
}

test "integration: nudge restarts and sends context prompt" {
    // Test that nudge restarts engine and sends context prompt (which invokes dot skill)
    // This test requires dot CLI to create real dots for nudge to trigger
    if (!dots.hasDotCli()) return error.SkipZigTest;

    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;

    // Use temp dir with real dot init
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Initialize dots and add a task
    var init_child = std.process.Child.init(&.{ "dot", "init" }, testing.allocator);
    init_child.cwd = tmp_path;
    init_child.stdin_behavior = .Ignore;
    init_child.stdout_behavior = .Ignore;
    init_child.stderr_behavior = .Ignore;
    const init_term = try init_child.spawnAndWait();
    if (init_term != .Exited or init_term.Exited != 0) return error.SkipZigTest;

    var add_child = std.process.Child.init(&.{ "dot", "add", "Test task" }, testing.allocator);
    add_child.cwd = tmp_path;
    add_child.stdin_behavior = .Ignore;
    add_child.stdout_behavior = .Ignore;
    add_child.stderr_behavior = .Ignore;
    const add_term = try add_child.spawnAndWait();
    if (add_term != .Exited or add_term.Exited != 0) return error.SkipZigTest;

    // Verify dots were created - skip if dot CLI doesn't work in temp dir
    const pending = dots.hasPendingTasks(testing.allocator, tmp_path);
    if (!pending.has_tasks) return error.SkipZigTest;

    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-nudge-order",
        .cwd = tmp_path,
        .cancelled = &cancelled,
        .nudge = .{ .enabled = true, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = Bridge.init(testing.allocator, tmp_path);
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: two tool_uses (to satisfy did_work which requires >1 tool)
    const tool_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}},{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}
    ;
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed1.value,
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    try queueClaudeResult(testing.allocator, &bridge, "success");
    try queueClaudeResult(testing.allocator, &bridge, "success");

    _ = try processClaudeMessages(&ctx, &bridge);

    // Verify restart was called
    try testing.expectEqual(@as(usize, 1), tracker.restart_count);

    // Verify prompts sent using snapshot
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (tracker.prompts.items, 0..) |p, i| {
        try out.writer.print("prompt[{d}]: {s}\n", .{ i, p });
    }
    for (tracker.user_msgs.items, 0..) |p, i| {
        try out.writer.print("user[{d}]: {s}\n", .{ i, p });
    }
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\prompt[0]: Read your project guidelines (AGENTS.md).
        \\Check your dots and pick one to work on.
        \\Keep going.
        \\user[0]: Read your project guidelines (AGENTS.md).
        \\Check your dots and pick one to work on.
        \\Keep going.
        \\
    ).diff(snapshot, true);
}

test "integration: Codex dot off triggers context reload" {
    // Test that a Codex command_execution with "dot off" followed by completion triggers context reload
    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-codex-dot-off",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = CodexBridge.init(testing.allocator, "/tmp");
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: item_started with "dot off abc123" command
    const arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    bridge.queue_mutex.lock();
    try bridge.pending_messages.append(testing.allocator, codex_bridge.CodexMessage{
        .event_type = .item_started,
        .item = .{
            .id = "tool-1",
            .kind = .command_execution,
            .command = "dot off abc123 -r done",
        },
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    // Inject: item_completed with exit_code=0
    const arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    bridge.queue_mutex.lock();
    try bridge.pending_messages.append(testing.allocator, codex_bridge.CodexMessage{
        .event_type = .item_completed,
        .item = .{
            .id = "tool-1",
            .kind = .command_execution,
            .aggregated_output = "Dot closed",
            .exit_code = 0,
        },
        .arena = arena2,
    });
    bridge.queue_mutex.unlock();

    try queueCodexTurn(testing.allocator, &bridge);
    try queueCodexTurn(testing.allocator, &bridge);

    _ = try processCodexMessages(&ctx, &bridge);

    // Verify context reload was triggered (clear + context_prompt)
    try testing.expect(tracker.hasContextReload());
}

test "integration: Codex dot off failure skips context reload" {
    // Test that a failed "dot off" (exit_code != 0) does NOT trigger context reload
    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-codex-dot-off-fail",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = CodexBridge.init(testing.allocator, "/tmp");
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: item_started with "dot off abc123" command
    const arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    bridge.queue_mutex.lock();
    try bridge.pending_messages.append(testing.allocator, codex_bridge.CodexMessage{
        .event_type = .item_started,
        .item = .{
            .id = "tool-1",
            .kind = .command_execution,
            .command = "dot off abc123 -r done",
        },
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    // Inject: item_completed with exit_code=1 (command failed)
    const arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    bridge.queue_mutex.lock();
    try bridge.pending_messages.append(testing.allocator, codex_bridge.CodexMessage{
        .event_type = .item_completed,
        .item = .{
            .id = "tool-1",
            .kind = .command_execution,
            .aggregated_output = "Error: dot not found",
            .exit_code = 1,
        },
        .arena = arena2,
    });
    bridge.queue_mutex.unlock();

    try queueCodexTurn(testing.allocator, &bridge);

    _ = try processCodexMessages(&ctx, &bridge);

    // Verify context reload was NOT triggered (no prompts sent)
    try testing.expect(!tracker.hasContextReload());
}

test "context reload returns context_reloaded stop reason" {
    // Test that context reload returns .context_reloaded instead of continuing
    // with the old bridge. The caller must get a new bridge and call again.
    // This is the key behavior that prevents reading from a dead bridge.
    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-reload-return",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    var bridge = Bridge.init(testing.allocator, "/tmp");
    defer bridge.deinit();
    bridge.reader_closed = true;

    // Inject: Bash tool_use with "dot off"
    const tool_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"dot off abc123"}}]}}
    ;
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed1.value,
        .arena = arena1,
    });
    bridge.queue_mutex.unlock();

    // Inject: tool_result (success triggers reload)
    const result_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"Done"}]}}
    ;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
    bridge.queue_mutex.lock();
    try bridge.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed2.value,
        .arena = arena2,
    });
    bridge.queue_mutex.unlock();

    // Inject: result message that would trigger the reload
    try queueClaudeResult(testing.allocator, &bridge, "success");

    // Process - should return context_reloaded, NOT end_turn
    const stop_reason = try processClaudeMessages(&ctx, &bridge);

    // Key assertion: must return context_reloaded so caller knows to get new bridge
    try testing.expectEqual(StopReason.context_reloaded, stop_reason);

    // Verify restart was called
    try testing.expectEqual(@as(usize, 1), tracker.restart_count);

    // Verify prompt was sent
    try testing.expectEqual(@as(usize, 1), tracker.prompts.items.len);
}

test "context reload caller loop pattern" {
    // Test the pattern callers must use: loop until not context_reloaded.
    // Simulates getting a new bridge after each reload.
    var tracker = ContextReloadTracker.init(testing.allocator);
    defer tracker.deinit();

    const vtable = createTestCallbacks(ContextReloadTracker);
    const cbs = EditorCallbacks{ .ctx = @ptrCast(&tracker), .vtable = &vtable };

    var cancelled = std.atomic.Value(bool).init(false);
    var last_nudge: i64 = 0;
    var ctx = PromptContext{
        .allocator = testing.allocator,
        .session_id = "test-caller-loop",
        .cwd = "/tmp",
        .cancelled = &cancelled,
        .nudge = .{ .enabled = false, .cooldown_ms = 0, .last_nudge_ms = &last_nudge },
        .cb = cbs,
    };

    // First bridge - will trigger reload
    var bridge1 = Bridge.init(testing.allocator, "/tmp");
    defer bridge1.deinit();
    bridge1.reader_closed = true;

    // Inject dot off -> triggers reload
    const tool_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"dot off x"}}]}}
    ;
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const p1 = try std.json.parseFromSlice(std.json.Value, arena1.allocator(), tool_json, .{});
    bridge1.queue_mutex.lock();
    try bridge1.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = p1.value,
        .arena = arena1,
    });
    bridge1.queue_mutex.unlock();

    const result_json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
    ;
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    const p2 = try std.json.parseFromSlice(std.json.Value, arena2.allocator(), result_json, .{});
    bridge1.queue_mutex.lock();
    try bridge1.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = p2.value,
        .arena = arena2,
    });
    bridge1.queue_mutex.unlock();

    try queueClaudeResult(testing.allocator, &bridge1, "success");

    // First call returns context_reloaded
    const r1 = try processClaudeMessages(&ctx, &bridge1);
    try testing.expectEqual(StopReason.context_reloaded, r1);

    // Second bridge - simulates new bridge after restart
    var bridge2 = Bridge.init(testing.allocator, "/tmp");
    defer bridge2.deinit();
    bridge2.reader_closed = true;

    // Inject normal completion (no reload trigger)
    const text_json =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}
    ;
    var arena3 = std.heap.ArenaAllocator.init(testing.allocator);
    const p3 = try std.json.parseFromSlice(std.json.Value, arena3.allocator(), text_json, .{});
    bridge2.queue_mutex.lock();
    try bridge2.message_queue.append(testing.allocator, claude_bridge.StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = p3.value,
        .arena = arena3,
    });
    bridge2.queue_mutex.unlock();

    try queueClaudeResult(testing.allocator, &bridge2, "end_turn");

    // Second call with new bridge returns end_turn (completes normally)
    const r2 = try processClaudeMessages(&ctx, &bridge2);
    try testing.expectEqual(StopReason.end_turn, r2);

    // Total: 1 restart, messages from both bridges processed
    try testing.expectEqual(@as(usize, 1), tracker.restart_count);
}

// Note: Live Claude context reload test removed.
// The integration tests (dot off triggers context reload, dot off skips subsequent nudge,
// nudge sends clear context trigger in order) comprehensively cover the context reload logic
// using mocked messages. A live test that asks Claude to run "dot off" is inherently flaky
// because it depends on non-deterministic LLM behavior (will Claude run the command?).
