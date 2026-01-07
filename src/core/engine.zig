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

const log = std.log.scoped(.engine);

const prompt_poll_ms: i64 = 250;

pub const NudgeConfig = struct {
    enabled: bool = true,
    cooldown_ms: i64 = 30_000,
    last_nudge_ms: *i64,
};

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

fn enginePrefix(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "[Claude] ",
        .codex => "[Codex] ",
    };
}

fn elapsedMs(start_ms: i64) u64 {
    const now = std.time.milliTimestamp();
    if (now <= start_ms) return 0;
    return @intCast(now - start_ms);
}

/// Process Claude Code messages from an active bridge.
/// Caller is responsible for sending the initial prompt and managing bridge lifecycle.
pub fn processClaudeMessages(
    ctx: *PromptContext,
    bridge: *Bridge,
) !StopReason {
    const start_ms = std.time.milliTimestamp();
    const engine: Engine = .claude;

    var stop_reason: StopReason = .end_turn;
    var first_response_ms: u64 = 0;
    var msg_count: u32 = 0;
    var stream_prefix_pending = false;
    var thought_prefix_pending = false;

    while (true) {
        if (ctx.isCancelled()) {
            stop_reason = .cancelled;
            break;
        }

        const deadline_ms = std.time.milliTimestamp() + prompt_poll_ms;
        var msg = bridge.readMessageWithTimeout(deadline_ms) catch |err| {
            if (err == error.Timeout) {
                ctx.cb.onTimeout();
                if (ctx.isCancelled()) {
                    stop_reason = .cancelled;
                    break;
                }
                continue;
            }
            if (err == error.EndOfStream) {
                log.info("Claude bridge closed", .{});
                break;
            }
            log.warn("Claude read error: {}", .{err});
            break;
        } orelse {
            log.info("Claude bridge returned null (EOF)", .{});
            break;
        };
        defer msg.deinit();

        msg_count += 1;
        const msg_time_ms = elapsedMs(start_ms);
        if (first_response_ms == 0) first_response_ms = msg_time_ms;
        log.debug("Claude msg #{d} ({s}) at {d}ms", .{ msg_count, @tagName(msg.type), msg_time_ms });

        switch (msg.type) {
            .assistant => {
                if (msg.getContent()) |content| {
                    if (first_response_ms == 0) {
                        first_response_ms = msg_time_ms;
                    }
                    try sendEngineText(ctx, engine, content);
                }

                if (msg.getToolUse()) |tool| {
                    try ctx.cb.sendToolCall(
                        ctx.session_id,
                        engine,
                        tool.name,
                        tool.name,
                        tool.id,
                        mapToolKind(tool.name),
                        tool.input,
                    );
                }

                if (msg.getToolResult()) |tool_result| {
                    const status: ToolStatus = if (tool_result.is_error) .failed else .completed;
                    try ctx.cb.sendToolResult(ctx.session_id, engine, tool_result.id, tool_result.content, status, tool_result.raw);
                }
            },
            .user => {
                if (msg.getToolResult()) |tool_result| {
                    const status: ToolStatus = if (tool_result.is_error) .failed else .completed;
                    try ctx.cb.sendToolResult(ctx.session_id, engine, tool_result.id, tool_result.content, status, tool_result.raw);
                }
            },
            .result => {
                if (msg.getStopReason()) |reason| {
                    const now_ms = std.time.milliTimestamp();
                    const cooldown_ok = (now_ms - ctx.nudge.last_nudge_ms.*) >= ctx.nudge.cooldown_ms;
                    const should_nudge = ctx.nudge.enabled and !ctx.isCancelled() and cooldown_ok and
                        dots.hasPendingTasks(ctx.allocator, ctx.cwd) and
                        (std.mem.eql(u8, reason, "error_max_turns") or
                            std.mem.eql(u8, reason, "success") or
                            std.mem.eql(u8, reason, "end_turn"));

                    if (should_nudge) {
                        ctx.nudge.last_nudge_ms.* = now_ms;
                        log.info("Claude Code stopped ({s}); pending dots, nudging", .{reason});
                        try ctx.cb.sendUserMessage(ctx.session_id, "🔄 continue working on pending dots");
                        const nudge_prompt = "clean up dots, then pick a dot and work on it";
                        const should_continue = try ctx.cb.sendContinuePrompt(.claude, nudge_prompt);
                        if (should_continue) {
                            stream_prefix_pending = true;
                            thought_prefix_pending = true;
                            continue;
                        } else {
                            stop_reason = mapCliStopReason(reason);
                            break;
                        }
                    } else if (!cooldown_ok) {
                        log.info("Claude Code stopped ({s}); not nudging due to cooldown", .{reason});
                    }
                    stop_reason = mapCliStopReason(reason);
                }
                break;
            },
            .stream_event => {
                if (msg.getStreamEventType()) |event_type| {
                    switch (event_type) {
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
                    if (stream_prefix_pending and ctx.tag_engine) {
                        try ctx.cb.sendTextRaw(ctx.session_id, enginePrefix(engine));
                        stream_prefix_pending = false;
                    }
                    try ctx.cb.sendTextRaw(ctx.session_id, text);
                }
                if (msg.getStreamThinkingDelta()) |thinking| {
                    if (thought_prefix_pending and ctx.tag_engine) {
                        try ctx.cb.sendThoughtRaw(ctx.session_id, enginePrefix(engine));
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

fn sendEngineText(ctx: *PromptContext, engine: Engine, text: []const u8) !void {
    if (ctx.tag_engine) {
        var buf: [4096]u8 = undefined;
        const prefix = enginePrefix(engine);
        if (prefix.len + text.len <= buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..][0..text.len], text);
            try ctx.cb.sendText(ctx.session_id, engine, buf[0 .. prefix.len + text.len]);
        } else {
            const tagged = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, text });
            defer ctx.allocator.free(tagged);
            try ctx.cb.sendText(ctx.session_id, engine, tagged);
        }
    } else {
        try ctx.cb.sendText(ctx.session_id, engine, text);
    }
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

fn isCodexMaxTurnError(err: codex_bridge.TurnError) bool {
    return containsMaxTurnMarker(err.code) or
        containsMaxTurnMarker(err.type) or
        containsMaxTurnMarker(err.message);
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
    var stream_prefix_pending = false;
    var thought_prefix_pending = false;

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
                if (first_response_ms == 0) first_response_ms = msg_time_ms;
                if (stream_prefix_pending and ctx.tag_engine) {
                    try ctx.cb.sendTextRaw(ctx.session_id, enginePrefix(engine));
                    stream_prefix_pending = false;
                }
                try ctx.cb.sendTextRaw(ctx.session_id, text);
            }
            continue;
        }

        if (msg.event_type == .reasoning_delta) {
            if (msg.text) |text| {
                if (first_response_ms == 0) first_response_ms = msg_time_ms;
                if (thought_prefix_pending and ctx.tag_engine) {
                    try ctx.cb.sendThoughtRaw(ctx.session_id, enginePrefix(engine));
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
            try ctx.cb.sendToolCall(
                ctx.session_id,
                engine,
                "Bash",
                tool.command,
                tool.id,
                .execute,
                null,
            );
            continue;
        }

        if (msg.getToolResult()) |tool_result| {
            const status = exitCodeStatus(tool_result.exit_code);
            try ctx.cb.sendToolResult(ctx.session_id, engine, tool_result.id, tool_result.content, status, tool_result.raw);
            continue;
        }

        if (msg.getThought()) |text| {
            if (first_response_ms == 0) first_response_ms = msg_time_ms;
            try sendEngineThought(ctx, engine, text);
            continue;
        }

        if (msg.getText()) |text| {
            if (first_response_ms == 0) first_response_ms = msg_time_ms;
            try sendEngineText(ctx, engine, text);
            continue;
        }

        if (msg.event_type == .turn_completed) {
            const has_max_turn_error = if (msg.turn_error) |err| isCodexMaxTurnError(err) else false;
            const has_blocking_error = msg.turn_error != null and !has_max_turn_error;
            const now_ms = std.time.milliTimestamp();
            const cooldown_ok = (now_ms - ctx.nudge.last_nudge_ms.*) >= ctx.nudge.cooldown_ms;
            const should_nudge = ctx.nudge.enabled and !ctx.isCancelled() and
                !has_blocking_error and cooldown_ok and
                dots.hasPendingTasks(ctx.allocator, ctx.cwd);

            if (should_nudge) {
                ctx.nudge.last_nudge_ms.* = now_ms;
                log.info("Codex turn completed; pending dots, nudging to continue", .{});
                try ctx.cb.sendUserMessage(ctx.session_id, "🔄 continue working on pending dots");
                const nudge_prompt = "continue with the next dot task";
                const should_continue = try ctx.cb.sendContinuePrompt(.codex, nudge_prompt);
                if (should_continue) {
                    stream_prefix_pending = true;
                    thought_prefix_pending = true;
                    continue;
                } else {
                    break;
                }
            } else if (has_blocking_error) {
                log.info("Codex turn completed; not nudging due to error", .{});
            } else if (!cooldown_ok) {
                log.info("Codex turn completed; not nudging due to cooldown", .{});
            }
        }

        if (msg.isTurnCompleted()) break;
    }

    const total_ms = elapsedMs(start_ms);
    log.info("Codex prompt complete: {d} msgs, first response at {d}ms, total {d}ms", .{ msg_count, first_response_ms, total_ms });
    return .end_turn;
}

fn sendEngineThought(ctx: *PromptContext, engine: Engine, text: []const u8) !void {
    if (ctx.tag_engine) {
        var buf: [4096]u8 = undefined;
        const prefix = enginePrefix(engine);
        if (prefix.len + text.len <= buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..][0..text.len], text);
            try ctx.cb.sendThought(ctx.session_id, engine, buf[0 .. prefix.len + text.len]);
        } else {
            const tagged = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, text });
            defer ctx.allocator.free(tagged);
            try ctx.cb.sendThought(ctx.session_id, engine, tagged);
        }
    } else {
        try ctx.cb.sendThought(ctx.session_id, engine, text);
    }
}

// Tests
const testing = std.testing;

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

    try testing.expect(!ctx.isCancelled());

    cancelled.store(true, .release);
    try testing.expect(ctx.isCancelled());

    cancelled.store(false, .release);
    try testing.expect(!ctx.isCancelled());
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
                std.Thread.yield() catch {};
            }
        }
    }.run, .{ &ctx, &seen_cancelled });

    // Writer thread sets cancelled after delay
    std.Thread.sleep(10 * std.time.ns_per_ms);
    cancelled.store(true, .release);

    reader.join();

    try testing.expect(seen_cancelled.load(.acquire));
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
        try testing.expectEqual(@as(u32, 10000), read_counts[i].load(.acquire));
    }
}
