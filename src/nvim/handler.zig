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
    cancelled: bool = false,
    nudge_enabled: bool = true,
    last_nudge_ms: i64 = 0,
    claude_session_id: ?[]const u8 = null,
    codex_session_id: ?[]const u8 = null,
    pending_permission: ?PendingPermission = null,
    mcp_server: ?*mcp_server_mod.McpServer = null,
    should_exit: bool = false,

    const PendingPermission = struct {
        id: []const u8,
        tool_name: []const u8,
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
        if (self.mcp_server) |mcp| {
            mcp.deinit();
        }
        if (self.claude_session_id) |sid| self.allocator.free(sid);
        if (self.codex_session_id) |sid| self.allocator.free(sid);
        if (self.owns_cwd) {
            self.allocator.free(self.cwd);
        }
    }

    pub fn run(self: *Handler) !void {
        // Start MCP server for Claude CLI discovery
        self.mcp_server = mcp_server_mod.McpServer.init(self.allocator, self.cwd) catch |err| {
            log.err("Failed to init MCP server: {}", .{err});
            return err;
        };

        if (self.mcp_server) |mcp| {
            mcp.start() catch |err| {
                log.err("Failed to start MCP server: {}", .{err});
            };

            // Send ready notification with MCP port
            try self.sendNotification("ready", ReadyNotification{ .mcp_port = mcp.getPort() });
        } else {
            try self.sendNotification("ready", .{});
        }

        var line_buf: [64 * 1024]u8 = undefined;
        while (true) {
            // Poll MCP server (non-blocking)
            if (self.mcp_server) |mcp| {
                _ = mcp.poll(0) catch |err| {
                    log.warn("MCP poll error: {}", .{err});
                };
            }

            // Check for graceful shutdown
            if (self.should_exit) break;

            // Try to read a line from stdin (with short timeout)
            const line = self.stdin.readUntilDelimiter(&line_buf, '\n') catch |err| {
                if (err == error.EndOfStream) break;
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                log.err("Read error: {}", .{err});
                continue;
            };

            self.handleLine(line) catch |err| {
                log.err("Handle error: {}", .{err});
                self.sendError("Internal error") catch {};
            };
        }
    }

    const ReadyNotification = struct {
        mcp_port: u16,
    };

    fn handleLine(self: *Handler, line: []const u8) !void {
        var parsed = std.json.parseFromSlice(protocol.JsonRpcRequest, self.allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Parse error: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const req = parsed.value;
        log.debug("Request: {s}", .{req.method});

        const method_map = std.StaticStringMap(*const fn (*Handler, protocol.JsonRpcRequest) anyerror!void).initComptime(.{
            .{ "prompt", handlePrompt },
            .{ "cancel", handleCancel },
            .{ "nudge_toggle", handleNudgeToggle },
            .{ "shutdown", handleShutdown },
            .{ "tool_response", handleToolResponse },
            .{ "selection_changed", handleSelectionChanged },
        });

        if (method_map.get(req.method)) |handler| {
            try handler(self, req);
        } else {
            log.warn("Unknown method: {s}", .{req.method});
        }
    }

    fn handleToolResponse(self: *Handler, req: protocol.JsonRpcRequest) !void {
        const params = req.params orelse return;

        // Parse tool response
        const response = std.json.parseFromValue(ToolResponseParams, self.allocator, params, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid tool_response params: {}", .{err});
            return;
        };
        defer response.deinit();

        // Forward to MCP server
        if (self.mcp_server) |mcp| {
            mcp.handleToolResponse(
                response.value.correlation_id,
                response.value.result,
                response.value.@"error",
            ) catch |err| {
                log.warn("Failed to handle tool response: {}", .{err});
            };
        }
    }

    const ToolResponseParams = struct {
        correlation_id: []const u8,
        result: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
    };

    fn handleSelectionChanged(self: *Handler, req: protocol.JsonRpcRequest) !void {
        const params = req.params orelse return;

        // Parse selection info
        const selection = std.json.parseFromValue(protocol.SelectionInfo, self.allocator, params, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid selection_changed params: {}", .{err});
            return;
        };
        defer selection.deinit();

        // Update MCP server's cached selection
        if (self.mcp_server) |mcp| {
            const range: ?mcp_types.SelectionRange = if (selection.value.range) |r| .{
                .startLine = r.start_line,
                .startCol = r.start_col,
                .endLine = r.end_line,
                .endCol = r.end_col,
            } else null;

            mcp.updateSelection(.{
                .text = selection.value.content orelse "",
                .file = selection.value.file,
                .range = range,
            }) catch |err| {
                log.warn("Failed to update selection cache: {}", .{err});
            };
        }
    }

    fn handlePrompt(self: *Handler, req: protocol.JsonRpcRequest) !void {
        const params = req.params orelse return;

        var prompt_parsed = std.json.parseFromValue(protocol.PromptRequest, self.allocator, params, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid prompt params: {}", .{err});
            return;
        };
        defer prompt_parsed.deinit();

        const prompt_req = prompt_parsed.value;
        self.cancelled = false;

        // Default to claude engine for now
        const engine: Engine = .claude;

        try self.sendNotification("stream_start", protocol.StreamStart{ .engine = engine });

        // Build prompt context
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

                bridge.start(.{}) catch |err| {
                    log.err("Failed to start Claude bridge: {}", .{err});
                    try self.sendError("Failed to start Claude");
                    return;
                };

                // Send the prompt
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

                // Send the prompt
                const inputs = [_]codex_bridge.CodexUserInput{
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

    fn handleCancel(self: *Handler, req: protocol.JsonRpcRequest) !void {
        _ = req;
        self.cancelled = true;
        try self.sendNotification("status", protocol.StatusUpdate{ .text = "Cancelled" });
    }

    fn handleNudgeToggle(self: *Handler, req: protocol.JsonRpcRequest) !void {
        _ = req;
        self.nudge_enabled = !self.nudge_enabled;
        const status = if (self.nudge_enabled) "Nudge enabled" else "Nudge disabled";
        try self.sendNotification("status", protocol.StatusUpdate{ .text = status });
    }

    fn handleShutdown(self: *Handler, req: protocol.JsonRpcRequest) !void {
        _ = req;
        log.info("Shutdown requested, cleaning up...", .{});
        self.should_exit = true;
    }

    fn sendNotification(self: *Handler, method: []const u8, params: anytype) !void {
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
            // For complex types, serialize params to json.Value
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
        .onApprovalRequest = null, // Not needed for basic nvim support
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

    fn cbSendToolCall(ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_name: []const u8, tool_label: []const u8, tool_id: []const u8, kind: ToolKind, input: ?std.json.Value) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = kind;
        _ = input;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("tool_call", protocol.ToolCall{
            .id = tool_id,
            .name = tool_name,
            .label = tool_label,
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
};

test "handler init/deinit" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(!handler.cancelled);
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

    // Toggle nudge
    try handler.handleNudgeToggle(protocol.JsonRpcRequest{
        .method = "nudge_toggle",
    });
    try std.testing.expect(!handler.nudge_enabled);

    // Toggle again
    try handler.handleNudgeToggle(protocol.JsonRpcRequest{
        .method = "nudge_toggle",
    });
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

    try std.testing.expect(!handler.cancelled);

    // Cancel
    try handler.handleCancel(protocol.JsonRpcRequest{
        .method = "cancel",
    });
    try std.testing.expect(handler.cancelled);
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
