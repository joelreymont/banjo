const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config");
const log = std.log.scoped(.codex_bridge);
const executable = @import("executable.zig");
const io_utils = @import("io_utils.zig");
const test_utils = @import("test_utils.zig");

const max_json_line_bytes: usize = 4 * 1024 * 1024;
const rpc_timeout_ms: i64 = 30_000;

pub const CodexMessage = struct {
    event_type: EventType,
    thread_id: ?[]const u8 = null,
    item: ?Item = null,
    text: ?[]const u8 = null,
    approval_request: ?ApprovalRequest = null,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CodexMessage) void {
        self.arena.deinit();
    }

    pub const EventType = enum {
        thread_started,
        turn_started,
        item_started,
        item_completed,
        turn_completed,
        agent_message_delta,
        reasoning_delta,
        approval_request,
        unknown,
    };

    pub const Item = struct {
        id: []const u8,
        kind: ItemKind,
        text: ?[]const u8 = null,
        command: ?[]const u8 = null,
        aggregated_output: ?[]const u8 = null,
        exit_code: ?i64 = null,
        status: ?[]const u8 = null,
    };

    pub const ItemKind = enum {
        agent_message,
        reasoning,
        command_execution,
        unknown,
    };

    pub const RpcRequestId = union(enum) {
        integer: i64,
        string: []const u8,
    };

    pub const ApprovalKind = enum {
        command_execution,
        file_change,
        exec_command,
        apply_patch,
    };

    pub const ApprovalRequest = struct {
        request_id: RpcRequestId,
        kind: ApprovalKind,
        params: std.json.Value,
    };

    pub const ToolCall = struct {
        id: []const u8,
        command: []const u8,
    };

    pub const ToolResult = struct {
        id: []const u8,
        content: ?[]const u8 = null,
        exit_code: ?i64 = null,
    };

    pub fn getText(self: *const CodexMessage) ?[]const u8 {
        if (self.text) |text| return text;
        if (self.event_type != .item_completed) return null;
        const item = self.item orelse return null;
        if (item.kind != .agent_message) return null;
        return item.text;
    }

    pub fn getThought(self: *const CodexMessage) ?[]const u8 {
        if (self.event_type == .reasoning_delta) return self.text;
        if (self.event_type != .item_completed) return null;
        const item = self.item orelse return null;
        if (item.kind != .reasoning) return null;
        return item.text;
    }

    pub fn getToolCall(self: *const CodexMessage) ?ToolCall {
        if (self.event_type != .item_started) return null;
        const item = self.item orelse return null;
        const command = item.command orelse return null;
        if (item.kind != .command_execution) return null;
        return .{ .id = item.id, .command = command };
    }

    pub fn getToolResult(self: *const CodexMessage) ?ToolResult {
        if (self.event_type != .item_completed) return null;
        const item = self.item orelse return null;
        if (item.kind != .command_execution) return null;
        if (item.command == null and item.aggregated_output == null and item.exit_code == null) return null;
        return .{
            .id = item.id,
            .content = item.aggregated_output,
            .exit_code = item.exit_code,
        };
    }

    pub fn getSessionId(self: *const CodexMessage) ?[]const u8 {
        if (self.event_type != .thread_started) return null;
        return self.thread_id;
    }

    pub fn getApprovalRequest(self: *const CodexMessage) ?ApprovalRequest {
        if (self.event_type != .approval_request) return null;
        return self.approval_request;
    }

    pub fn isTurnCompleted(self: *const CodexMessage) bool {
        return self.event_type == .turn_completed;
    }
};

const RpcEnvelope = struct {
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?std.json.Value = null,
};

const InitializeParams = struct {
    clientInfo: ClientInfo,
};

const ClientInfo = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    version: []const u8,
};

const InitializeResponse = struct {
    userAgent: []const u8,
};

const ThreadStartParams = struct {
    model: ?[]const u8 = null,
    modelProvider: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    approvalPolicy: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
    config: ?std.json.Value = null,
    baseInstructions: ?[]const u8 = null,
    developerInstructions: ?[]const u8 = null,
    experimentalRawEvents: bool = false,
};

const ThreadResumeParams = struct {
    threadId: []const u8,
};

const ThreadRef = struct {
    id: []const u8,
};

const ThreadStartResponse = struct {
    thread: ThreadRef,
};

pub const UserInput = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

const TurnStartParams = struct {
    threadId: []const u8,
    input: []const UserInput,
    cwd: ?[]const u8 = null,
    approvalPolicy: ?[]const u8 = null,
    sandboxPolicy: ?std.json.Value = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    summary: ?[]const u8 = null,
};

const TurnRef = struct {
    id: []const u8,
};

const TurnStartResponse = struct {
    turn: ?TurnRef = null,
    turnId: ?[]const u8 = null,
};

const ThreadStartedParams = struct {
    thread: ThreadRef,
};

const TurnStartedParams = struct {
    threadId: ?[]const u8 = null,
    turn: ?TurnRef = null,
    turnId: ?[]const u8 = null,
};

const TurnCompletedParams = struct {
    threadId: ?[]const u8 = null,
    turn: ?TurnRef = null,
    turnId: ?[]const u8 = null,
};

const ItemDeltaParams = struct {
    threadId: ?[]const u8 = null,
    turnId: ?[]const u8 = null,
    itemId: ?[]const u8 = null,
    delta: ?[]const u8 = null,
};

const ItemEventParams = struct {
    threadId: ?[]const u8 = null,
    turnId: ?[]const u8 = null,
    item: ItemData,
};

const ReasoningLineEntry = struct {
    text: ?[]const u8 = null,

    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!ReasoningLineEntry {
        _ = options;
        const ReasoningLineObject = struct {
            text: ?[]const u8 = null,
        };
        return switch (source) {
            .string => |text| .{ .text = text },
            .object => {
                const parsed = try std.json.parseFromValue(ReasoningLineObject, allocator, source, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                return .{ .text = parsed.value.text };
            },
            .null => .{ .text = null },
            else => error.UnexpectedToken,
        };
    }
};

const ReasoningLines = struct {
    lines: []const []const u8,

    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ReasoningLines {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!ReasoningLines {
        _ = options;
        switch (source) {
            .string => |text| {
                const lines = try allocator.alloc([]const u8, 1);
                lines[0] = text;
                return .{ .lines = lines };
            },
            .null => {
                const lines = try allocator.alloc([]const u8, 0);
                return .{ .lines = lines };
            },
            .array => {
                const parsed = try std.json.parseFromValueLeaky([]ReasoningLineEntry, allocator, source, .{
                    .ignore_unknown_fields = true,
                });
                var list: std.ArrayList([]const u8) = .empty;
                defer list.deinit(allocator);
                for (parsed) |entry| {
                    if (entry.text) |text| {
                        try list.append(allocator, text);
                    }
                }
                return .{ .lines = try list.toOwnedSlice(allocator) };
            },
            else => return error.UnexpectedToken,
        }
    }
};

const ItemData = struct {
    id: []const u8,
    type: []const u8,
    text: ?[]const u8 = null,
    summary: ?ReasoningLines = null,
    content: ?ReasoningLines = null,
    command: ?[]const u8 = null,
    aggregatedOutput: ?[]const u8 = null,
    aggregated_output: ?[]const u8 = null,
    exitCode: ?i64 = null,
    exit_code: ?i64 = null,
    status: ?[]const u8 = null,
};

const CommandExecutionRequestApprovalParams = struct {
    threadId: []const u8,
    turnId: []const u8,
    itemId: []const u8,
    reason: ?[]const u8 = null,
    proposedExecpolicyAmendment: ?std.json.Value = null,
};

const FileChangeRequestApprovalParams = struct {
    threadId: []const u8,
    turnId: []const u8,
    itemId: []const u8,
    reason: ?[]const u8 = null,
    grantRoot: ?[]const u8 = null,
};

const ApplyPatchApprovalParams = struct {
    conversationId: []const u8,
    callId: []const u8,
    fileChanges: std.json.Value,
    reason: ?[]const u8 = null,
    grantRoot: ?[]const u8 = null,
};

const ExecCommandApprovalParams = struct {
    conversationId: []const u8,
    callId: []const u8,
    command: std.json.Value,
    cwd: []const u8,
    reason: ?[]const u8 = null,
    parsedCmd: std.json.Value,
};

pub const CodexBridge = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    cwd: []const u8,
    stdout_file: ?std.fs.File = null,
    next_request_id: i64 = 1,
    thread_id: ?[]const u8 = null,
    current_turn_id: ?[]const u8 = null,
    approval_policy: ?[]const u8 = null,
    saw_agent_delta: bool = false,
    saw_reasoning_delta: bool = false,
    pending_messages: std.ArrayList(CodexMessage) = .empty,
    pending_head: usize = 0,
    line_buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator, cwd: []const u8) CodexBridge {
        return .{
            .allocator = allocator,
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *CodexBridge) void {
        self.stop();
        if (self.thread_id) |thread_id| {
            self.allocator.free(thread_id);
            self.thread_id = null;
        }
        if (self.current_turn_id) |turn_id| {
            self.allocator.free(turn_id);
            self.current_turn_id = null;
        }
        self.clearPendingMessages();
        self.pending_messages.deinit(self.allocator);
        self.line_buffer.deinit(self.allocator);
    }

    fn clearPendingMessages(self: *CodexBridge) void {
        for (self.pending_messages.items[self.pending_head..]) |*msg| {
            msg.deinit();
        }
        self.pending_messages.clearRetainingCapacity();
        self.pending_head = 0;
    }

    fn findCodexBinary() []const u8 {
        return executable.choose("CODEX_EXECUTABLE", "codex", codex_paths[0..]);
    }

    const codex_paths = [_][]const u8{
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
    };

    pub fn isAvailable() bool {
        return executable.isAvailable("CODEX_EXECUTABLE", "codex", codex_paths[0..]);
    }

    pub const StartOptions = struct {
        resume_session_id: ?[]const u8 = null,
        model: ?[]const u8 = null,
        approval_policy: ?[]const u8 = null,
    };

    pub fn getThreadId(self: *const CodexBridge) ?[]const u8 {
        return self.thread_id;
    }

    pub fn start(self: *CodexBridge, opts: StartOptions) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        const codex_path = findCodexBinary();
        log.info("Using codex binary: {s}", .{codex_path});

        try args.appendSlice(self.allocator, &[_][]const u8{
            codex_path,
            "app-server",
        });

        var child = std.process.Child.init(args.items, self.allocator);
        child.cwd = self.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.process = child;
        self.stdout_file = self.process.?.stdout;
        self.line_buffer.clearRetainingCapacity();

        self.approval_policy = opts.approval_policy;
        try self.initialize();

        if (opts.resume_session_id) |sid| {
            self.resumeThread(sid, opts.model) catch |err| {
                log.warn("Failed to resume Codex thread ({s}): {}", .{ sid, err });
                try self.startThread(opts.model);
                return;
            };
        } else {
            try self.startThread(opts.model);
        }
    }

    pub fn stop(self: *CodexBridge) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
            self.stdout_file = null;
            self.saw_agent_delta = false;
            self.saw_reasoning_delta = false;
            self.clearPendingMessages();
            self.line_buffer.clearRetainingCapacity();
            log.info("Stopped Codex", .{});
        }
    }

    pub fn sendPrompt(self: *CodexBridge, inputs: []const UserInput) !void {
        const thread_id = self.thread_id orelse return error.NotStarted;
        const request_id = self.nextRequestId();

        const params = TurnStartParams{
            .threadId = thread_id,
            .input = inputs,
            .approvalPolicy = self.approval_policy,
        };

        try self.sendRequest(request_id, "turn/start", params);
        var response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const turn_id = extractTurnId(response.arena.allocator(), response.value) orelse {
            return error.InvalidResponse;
        };
        try self.setTurnId(turn_id);
        self.saw_agent_delta = false;
        self.saw_reasoning_delta = false;
    }

    pub fn readMessage(self: *CodexBridge) !?CodexMessage {
        if (self.pending_head < self.pending_messages.items.len) {
            const msg = self.pending_messages.items[self.pending_head];
            self.pending_head += 1;
            if (self.pending_head >= self.pending_messages.items.len) {
                self.pending_messages.clearRetainingCapacity();
                self.pending_head = 0;
            }
            return msg;
        }

        while (true) {
            var rpc_message = (try self.readRpcMessage()) orelse return null;
            var keep_arena = false;
            defer if (!keep_arena) rpc_message.arena.deinit();

            switch (rpc_message.kind) {
                .notification => {
                    const method = rpc_message.method orelse {
                        continue;
                    };
                    const params = rpc_message.params orelse {
                        continue;
                    };
                    if (self.mapNotification(&rpc_message.arena, method, params)) |msg| {
                        keep_arena = true;
                        return msg;
                    }
                },
                .request => {
                    if (self.mapServerRequest(&rpc_message.arena, rpc_message)) |msg| {
                        keep_arena = true;
                        return msg;
                    }
                },
                .response, .err, .unknown => {},
            }
        }
    }

    pub fn readMessageWithTimeout(self: *CodexBridge, deadline_ms: i64) !?CodexMessage {
        if (self.pending_head < self.pending_messages.items.len) {
            const msg = self.pending_messages.items[self.pending_head];
            self.pending_head += 1;
            if (self.pending_head >= self.pending_messages.items.len) {
                self.pending_messages.clearRetainingCapacity();
                self.pending_head = 0;
            }
            return msg;
        }

        while (true) {
            var rpc_message = (try self.readRpcMessageWithTimeout(deadline_ms)) orelse return null;
            var keep_arena = false;
            defer if (!keep_arena) rpc_message.arena.deinit();

            switch (rpc_message.kind) {
                .notification => {
                    const method = rpc_message.method orelse {
                        continue;
                    };
                    const params = rpc_message.params orelse {
                        continue;
                    };
                    if (self.mapNotification(&rpc_message.arena, method, params)) |msg| {
                        keep_arena = true;
                        return msg;
                    }
                },
                .request => {
                    if (self.mapServerRequest(&rpc_message.arena, rpc_message)) |msg| {
                        keep_arena = true;
                        return msg;
                    }
                },
                .response, .err, .unknown => {},
            }
        }
    }

    fn initialize(self: *CodexBridge) !void {
        const request_id = self.nextRequestId();
        const params = InitializeParams{
            .clientInfo = .{
                .name = "banjo-duet",
                .title = "Banjo Duet",
                .version = config.version,
            },
        };
        try self.sendRequest(request_id, "initialize", params);
        var response = try self.waitForResponse(request_id);
        response.arena.deinit();
        try self.sendNotification("initialized");
    }

    fn startThread(self: *CodexBridge, model: ?[]const u8) !void {
        const request_id = self.nextRequestId();
        const params = ThreadStartParams{
            .model = model,
            .cwd = self.cwd,
            .approvalPolicy = self.approval_policy,
            .experimentalRawEvents = false,
        };
        try self.sendRequest(request_id, "thread/start", params);
        var response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const thread_id = extractThreadId(response.arena.allocator(), response.value) orelse {
            return error.InvalidResponse;
        };
        try self.setThreadId(thread_id);
    }

    fn resumeThread(self: *CodexBridge, thread_id: []const u8, model: ?[]const u8) !void {
        _ = model;
        const request_id = self.nextRequestId();
        const params = ThreadResumeParams{
            .threadId = thread_id,
        };
        try self.sendRequest(request_id, "thread/resume", params);
        var response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const resumed_id = extractThreadId(response.arena.allocator(), response.value) orelse {
            return error.InvalidResponse;
        };
        try self.setThreadId(resumed_id);
    }

    fn setThreadId(self: *CodexBridge, thread_id: []const u8) !void {
        if (self.thread_id) |existing| {
            self.allocator.free(existing);
        }
        self.thread_id = try self.allocator.dupe(u8, thread_id);
    }

    fn setTurnId(self: *CodexBridge, turn_id: []const u8) !void {
        if (self.current_turn_id) |existing| {
            self.allocator.free(existing);
        }
        self.current_turn_id = try self.allocator.dupe(u8, turn_id);
    }

    fn sendRequest(self: *CodexBridge, request_id: i64, method: []const u8, params: anytype) !void {
        const payload = .{
            .id = request_id,
            .method = method,
            .params = params,
        };
        try self.writeJsonLine(payload);
    }

    fn sendNotification(self: *CodexBridge, method: []const u8) !void {
        const payload = .{ .method = method };
        try self.writeJsonLine(payload);
    }

    fn sendResponseId(self: *CodexBridge, request_id: CodexMessage.RpcRequestId, result: anytype) !void {
        switch (request_id) {
            .integer => |id| {
                const payload = .{ .id = id, .result = result };
                try self.writeJsonLine(payload);
            },
            .string => |id| {
                const payload = .{ .id = id, .result = result };
                try self.writeJsonLine(payload);
            },
        }
    }

    pub fn respondApproval(self: *CodexBridge, request_id: CodexMessage.RpcRequestId, decision: []const u8) !void {
        try self.sendResponseId(request_id, .{ .decision = decision });
    }

    fn writeJsonLine(self: *CodexBridge, payload: anytype) !void {
        const proc = self.process orelse return error.NotStarted;
        const stdin = proc.stdin orelse return error.NoStdin;
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{
            .emit_null_optional_fields = false,
        });
        defer self.allocator.free(json);
        try stdin.writeAll(json);
        try stdin.writeAll("\n");
    }

    const ResponsePayload = struct {
        arena: std.heap.ArenaAllocator,
        value: std.json.Value,
    };

    fn waitForResponse(self: *CodexBridge, request_id: i64) !ResponsePayload {
        const deadline = std.time.milliTimestamp() + rpc_timeout_ms;
        while (true) {
            var rpc_message = (try self.readRpcMessageWithTimeout(deadline)) orelse return error.UnexpectedEof;
            var keep_arena = false;
            defer if (!keep_arena) rpc_message.arena.deinit();

            switch (rpc_message.kind) {
                .response => {
                    const id_value = rpc_message.id orelse {
                        continue;
                    };
                    if (parseRequestId(id_value)) |id| {
                        if (id == request_id) {
                            const result = rpc_message.result orelse return error.InvalidResponse;
                            keep_arena = true;
                            return .{ .arena = rpc_message.arena, .value = result };
                        }
                    }
                },
                .err => {
                    const id_value = rpc_message.id orelse {
                        continue;
                    };
                    if (parseRequestId(id_value)) |id| {
                        if (id == request_id) {
                            log.err("Codex app-server error response for request {d}", .{request_id});
                            return error.RequestFailed;
                        }
                    }
                },
                .notification => {
                    const method = rpc_message.method orelse {
                        continue;
                    };
                    const params = rpc_message.params orelse {
                        continue;
                    };
                    if (self.mapNotification(&rpc_message.arena, method, params)) |msg| {
                        keep_arena = true;
                        try self.pending_messages.append(self.allocator, msg);
                    }
                },
                .request => {
                    if (self.mapServerRequest(&rpc_message.arena, rpc_message)) |msg| {
                        keep_arena = true;
                        try self.pending_messages.append(self.allocator, msg);
                    }
                },
                .unknown => {},
            }
        }
    }

    fn readRpcMessageWithTimeout(self: *CodexBridge, deadline_ms: i64) !?RpcMessage {
        return self.readRpcMessageWithDeadline(deadline_ms);
    }

    const RpcMessage = struct {
        kind: Kind,
        arena: std.heap.ArenaAllocator,
        id: ?std.json.Value = null,
        method: ?[]const u8 = null,
        params: ?std.json.Value = null,
        result: ?std.json.Value = null,
        err: ?std.json.Value = null,

        const Kind = enum {
            request,
            notification,
            response,
            err,
            unknown,
        };
    };

    fn readRpcMessage(self: *CodexBridge) !?RpcMessage {
        return self.readRpcMessageWithDeadline(null);
    }

    fn readRpcMessageWithDeadline(self: *CodexBridge, deadline_ms: ?i64) !?RpcMessage {
        _ = self.process orelse return error.NotStarted;

        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            var keep_arena = false;
            defer if (!keep_arena) arena.deinit();

            const line = (try self.readLine(arena.allocator(), deadline_ms)) orelse return null;

            const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), line, .{
                .ignore_unknown_fields = true,
            });

            const envelope = parsed.value;
            var kind: RpcMessage.Kind = .unknown;

            if (envelope.method) |_| {
                if (envelope.id != null) {
                    kind = .request;
                } else {
                    kind = .notification;
                }
            } else if (envelope.result != null and envelope.id != null) {
                kind = .response;
            } else if (envelope.@"error" != null and envelope.id != null) {
                kind = .err;
            }

            keep_arena = true;
            return RpcMessage{
                .kind = kind,
                .arena = arena,
                .id = envelope.id,
                .method = envelope.method,
                .params = envelope.params,
                .result = envelope.result,
                .err = envelope.@"error",
            };
        }
    }

    fn readLine(self: *CodexBridge, arena: Allocator, deadline_ms: ?i64) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.line_buffer.items, '\n')) |nl| {
                const line_len = nl;
                if (line_len == 0) {
                    self.discardLinePrefix(nl + 1);
                    continue;
                }
                if (line_len > max_json_line_bytes) return error.LineTooLong;
                const line = try arena.alloc(u8, line_len);
                @memcpy(line, self.line_buffer.items[0..line_len]);
                self.discardLinePrefix(nl + 1);
                return line;
            }

            if (deadline_ms) |deadline| {
                const now = std.time.milliTimestamp();
                if (now >= deadline) return error.Timeout;
                const slice_ms = io_utils.pollSliceMs(deadline, now);
                const readable = try waitForReadable(self, slice_ms);
                if (!readable) continue;
            } else {
                _ = try waitForReadable(self, -1);
            }

            const stdout = self.stdout_file orelse return error.NoStdout;
            var buf: [4096]u8 = undefined;
            const count = stdout.read(&buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (count == 0) {
                if (self.line_buffer.items.len == 0) return null;
                const line = try arena.alloc(u8, self.line_buffer.items.len);
                @memcpy(line, self.line_buffer.items);
                self.line_buffer.clearRetainingCapacity();
                return line;
            }
            try self.line_buffer.appendSlice(self.allocator, buf[0..count]);
            if (self.line_buffer.items.len > max_json_line_bytes) return error.LineTooLong;
        }
    }

    fn discardLinePrefix(self: *CodexBridge, count: usize) void {
        const remaining = self.line_buffer.items.len - count;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.line_buffer.items[0..remaining], self.line_buffer.items[count..]);
        }
        self.line_buffer.items.len = remaining;
    }

    fn mapServerRequest(self: *CodexBridge, arena: *std.heap.ArenaAllocator, msg: RpcMessage) ?CodexMessage {
        const method = msg.method orelse return null;
        const params = msg.params orelse return null;
        const request_id_value = msg.id orelse return null;
        const request_id = parseRpcRequestId(request_id_value) orelse return null;

        const kind = serverRequestKind(method);
        if (kind == .unknown) {
            self.sendResponseId(request_id, .{ .decision = "decline" }) catch |err| {
                log.warn("Failed to respond to unknown Codex request: {}", .{err});
            };
            return null;
        }

        if (!parseServerRequestParams(arena.allocator(), kind, params)) {
            self.sendResponseId(request_id, .{ .decision = "decline" }) catch |err| {
                log.warn("Failed to respond to invalid Codex request: {}", .{err});
            };
            return null;
        }

        return CodexMessage{
            .event_type = .approval_request,
            .approval_request = .{
                .request_id = request_id,
                .kind = kind.toApprovalKind(),
                .params = params,
            },
            .arena = arena.*,
        };
    }

    fn mapNotification(
        self: *CodexBridge,
        arena: *std.heap.ArenaAllocator,
        method: []const u8,
        params: std.json.Value,
    ) ?CodexMessage {
        const kind = notificationKind(method);
        switch (kind) {
            .thread_started => {
                const parsed = parseNotificationParams(arena, ThreadStartedParams, params) orelse return null;
                return CodexMessage{
                    .event_type = .thread_started,
                    .thread_id = parsed.thread.id,
                    .arena = arena.*,
                };
            },
            .turn_started => {
                _ = parseNotificationParams(arena, TurnStartedParams, params) orelse return null;
                return CodexMessage{
                    .event_type = .turn_started,
                    .arena = arena.*,
                };
            },
            .turn_completed => {
                const parsed = parseNotificationParams(arena, TurnCompletedParams, params) orelse {
                    log.warn("Codex turn_completed parse failed", .{});
                    return null;
                };
                const turn_id = if (parsed.turn) |turn|
                    turn.id
                else
                    parsed.turnId orelse {
                        log.warn("Codex turn_completed missing turnId", .{});
                        return null;
                    };
                if (!self.matchesCurrentTurn(turn_id)) {
                    log.warn("Codex turn_completed ignored for turn {s}", .{turn_id});
                    return null;
                }
                return CodexMessage{
                    .event_type = .turn_completed,
                    .thread_id = parsed.threadId,
                    .arena = arena.*,
                };
            },
            .agent_message_delta => {
                const parsed = parseNotificationParams(arena, ItemDeltaParams, params) orelse return null;
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const delta = parsed.delta orelse return null;
                self.saw_agent_delta = true;
                return CodexMessage{
                    .event_type = .agent_message_delta,
                    .text = delta,
                    .arena = arena.*,
                };
            },
            .reasoning_summary_delta => {
                const parsed = parseNotificationParams(arena, ItemDeltaParams, params) orelse return null;
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const delta = parsed.delta orelse return null;
                self.saw_reasoning_delta = true;
                return CodexMessage{
                    .event_type = .reasoning_delta,
                    .text = delta,
                    .arena = arena.*,
                };
            },
            .reasoning_text_delta => {
                if (self.saw_reasoning_delta) return null;
                const parsed = parseNotificationParams(arena, ItemDeltaParams, params) orelse return null;
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const delta = parsed.delta orelse return null;
                self.saw_reasoning_delta = true;
                return CodexMessage{
                    .event_type = .reasoning_delta,
                    .text = delta,
                    .arena = arena.*,
                };
            },
            .item_started, .item_completed => {
                const parsed = parseNotificationParams(arena, ItemEventParams, params) orelse return null;
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const item = parseItem(arena.allocator(), parsed.item) orelse return null;
                const event_type: CodexMessage.EventType = if (kind == .item_started) .item_started else .item_completed;

                if (event_type == .item_completed and item.kind == .agent_message and self.saw_agent_delta) {
                    return null;
                }

                if (event_type == .item_completed and item.kind == .reasoning and self.saw_reasoning_delta) {
                    return null;
                }

                if (event_type == .item_started and item.kind != .command_execution) {
                    return null;
                }

                return CodexMessage{
                    .event_type = event_type,
                    .item = item,
                    .arena = arena.*,
                };
            },
            .unknown => return null,
        }
    }

    fn nextRequestId(self: *CodexBridge) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn matchesCurrentTurn(self: *CodexBridge, turn_id: ?[]const u8) bool {
        if (self.current_turn_id) |current| {
            const id = turn_id orelse {
                log.warn("Codex event missing turnId (expected {s})", .{current});
                return true;
            };
            if (!std.mem.eql(u8, current, id)) {
                log.warn("Codex turn ID mismatch: expected {s}, got {s}", .{ current, id });
                return false;
            }
        }
        return true;
    }
};

fn parseRequestId(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .string => |str| std.fmt.parseInt(i64, str, 10) catch null,
        else => null,
    };
}

fn extractThreadId(allocator: Allocator, value: std.json.Value) ?[]const u8 {
    const parsed = std.json.parseFromValueLeaky(ThreadStartResponse, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("Failed to parse thread start response: {}", .{err});
        return null;
    };
    return parsed.thread.id;
}

fn extractTurnId(allocator: Allocator, value: std.json.Value) ?[]const u8 {
    const parsed = std.json.parseFromValueLeaky(TurnStartResponse, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("Failed to parse turn start response: {}", .{err});
        return null;
    };
    if (parsed.turn) |turn| return turn.id;
    return parsed.turnId;
}

fn parseItem(allocator: Allocator, item: ItemData) ?CodexMessage.Item {
    const kind = parseItemKind(item.type);

    var parsed = CodexMessage.Item{
        .id = item.id,
        .kind = kind,
    };

    if (kind == .agent_message) {
        parsed.text = item.text;
        return parsed;
    }

    if (kind == .reasoning) {
        if (item.summary) |summary_val| {
            parsed.text = joinStringLines(allocator, summary_val.lines, "\n");
        }
        if (parsed.text == null) {
            if (item.content) |content_val| {
                parsed.text = joinStringLines(allocator, content_val.lines, "\n");
            }
        }
        return parsed;
    }

    if (kind == .command_execution) {
        parsed.command = item.command;
        parsed.aggregated_output = item.aggregatedOutput orelse item.aggregated_output;
        parsed.exit_code = item.exitCode orelse item.exit_code;
        parsed.status = item.status;
        return parsed;
    }

    return parsed;
}

fn parseItemKind(item_type: []const u8) CodexMessage.ItemKind {
    const map = std.StaticStringMap(CodexMessage.ItemKind).initComptime(.{
        .{ "agent_message", .agent_message },
        .{ "agentMessage", .agent_message },
        .{ "reasoning", .reasoning },
        .{ "command_execution", .command_execution },
        .{ "commandExecution", .command_execution },
    });
    return map.get(item_type) orelse .unknown;
}

fn notificationKind(method: []const u8) NotificationKind {
    const map = std.StaticStringMap(NotificationKind).initComptime(.{
        .{ "thread/started", .thread_started },
        .{ "turn/started", .turn_started },
        .{ "turn/completed", .turn_completed },
        .{ "item/agentMessage/delta", .agent_message_delta },
        .{ "item/reasoning/summaryTextDelta", .reasoning_summary_delta },
        .{ "item/reasoning/textDelta", .reasoning_text_delta },
        .{ "item/started", .item_started },
        .{ "item/agentMessage/started", .item_started },
        .{ "item/commandExecution/started", .item_started },
        .{ "item/completed", .item_completed },
        .{ "item/agentMessage/completed", .item_completed },
        .{ "item/reasoning/completed", .item_completed },
        .{ "item/commandExecution/completed", .item_completed },
    });
    return map.get(method) orelse .unknown;
}

fn parseRpcRequestId(value: std.json.Value) ?CodexMessage.RpcRequestId {
    return switch (value) {
        .integer => |int| .{ .integer = int },
        .string => |str| .{ .string = str },
        else => null,
    };
}

fn serverRequestKind(method: []const u8) ServerRequestKind {
    const map = std.StaticStringMap(ServerRequestKind).initComptime(.{
        .{ "item/commandExecution/requestApproval", .command_execution },
        .{ "item/fileChange/requestApproval", .file_change },
        .{ "applyPatchApproval", .apply_patch },
        .{ "execCommandApproval", .exec_command },
    });
    return map.get(method) orelse .unknown;
}

fn parseServerRequestParams(allocator: Allocator, kind: ServerRequestKind, params: std.json.Value) bool {
    return switch (kind) {
        .command_execution => parseParams(allocator, CommandExecutionRequestApprovalParams, params),
        .file_change => parseParams(allocator, FileChangeRequestApprovalParams, params),
        .apply_patch => parseParams(allocator, ApplyPatchApprovalParams, params),
        .exec_command => parseParams(allocator, ExecCommandApprovalParams, params),
        .unknown => false,
    };
}

fn parseNotificationParams(arena: *std.heap.ArenaAllocator, comptime T: type, params: std.json.Value) ?T {
    const parsed = std.json.parseFromValue(T, arena.allocator(), params, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("Failed to parse {s} params: {}", .{@typeName(T), err});
        return null;
    };
    defer parsed.deinit();
    return parsed.value;
}

fn parseParams(allocator: Allocator, comptime T: type, value: std.json.Value) bool {
    const parsed = std.json.parseFromValue(T, allocator, value, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("Failed to parse {s} params: {}", .{@typeName(T), err});
        return false;
    };
    parsed.deinit();
    return true;
}

const NotificationKind = enum {
    thread_started,
    turn_started,
    turn_completed,
    agent_message_delta,
    reasoning_summary_delta,
    reasoning_text_delta,
    item_started,
    item_completed,
    unknown,
};

const ServerRequestKind = enum {
    command_execution,
    file_change,
    exec_command,
    apply_patch,
    unknown,

    fn toApprovalKind(self: ServerRequestKind) CodexMessage.ApprovalKind {
        return switch (self) {
            .command_execution => .command_execution,
            .file_change => .file_change,
            .exec_command => .exec_command,
            .apply_patch => .apply_patch,
            .unknown => .command_execution,
        };
    }
};

fn joinStringLines(allocator: Allocator, lines: []const []const u8, sep: []const u8) ?[]const u8 {
    if (lines.len == 0) return null;

    var total_len: usize = 0;
    for (lines) |line| {
        total_len += line.len;
    }
    total_len += sep.len * (lines.len - 1);

    const buf = allocator.alloc(u8, total_len) catch return null;
    var offset: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx != 0) {
            std.mem.copyForwards(u8, buf[offset..][0..sep.len], sep);
            offset += sep.len;
        }
        std.mem.copyForwards(u8, buf[offset..][0..line.len], line);
        offset += line.len;
    }
    return buf;
}

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "CodexMessage agent message delta parsing" {
    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"Hello"}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var bridge = CodexBridge.init(testing.allocator, ".");
    var msg = bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    try testing.expectEqualStrings("Hello", msg.getText().?);
}

test "CodexMessage command execution item parsing" {
    const json =
        \\{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"item_2","command":"/bin/zsh -lc ls","cwd":"/tmp","processId":null,"status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1}}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var bridge = CodexBridge.init(testing.allocator, ".");
    var msg = bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const tool = msg.getToolResult().?;
    try testing.expectEqualStrings("item_2", tool.id);
    try testing.expectEqualStrings("ok", tool.content.?);
    try testing.expectEqual(@as(i64, 0), tool.exit_code.?);
}

test "CodexMessage thread started parsing" {
    const json =
        \\{"method":"thread/started","params":{"thread":{"id":"thr_123"}}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var bridge = CodexBridge.init(testing.allocator, ".");
    var msg = bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    try testing.expectEqualStrings("thr_123", msg.getSessionId().?);
}

test "CodexMessage reasoning summary parsing" {
    const json =
        \\{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"reasoning","id":"item_9","summary":["First","Second"],"content":[]}}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var bridge = CodexBridge.init(testing.allocator, ".");
    var msg = bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    try testing.expectEqualStrings("First\nSecond", msg.getThought().?);
}

test "CodexMessage tool call parsing from item started" {
    const json =
        \\{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"item_3","command":"/bin/zsh -lc ls","cwd":"/tmp","processId":null,"status":"inProgress","commandActions":[],"aggregatedOutput":null,"exitCode":null,"durationMs":null}}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var bridge = CodexBridge.init(testing.allocator, ".");
    var msg = bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const tool = msg.getToolCall().?;
    try testing.expectEqualStrings("item_3", tool.id);
    try testing.expectEqualStrings("/bin/zsh -lc ls", tool.command);
}

test "CodexMessage item completed suppressed after agent delta" {
    const delta_json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"Hello"}}
    ;
    const completed_json =
        \\{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"agentMessage","id":"item_1","text":"Hello"}}}
    ;

    var bridge = CodexBridge.init(testing.allocator, ".");

    var arena_delta = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed_delta = try std.json.parseFromSlice(RpcEnvelope, arena_delta.allocator(), delta_json, .{
        .ignore_unknown_fields = true,
    });
    var delta_msg = bridge.mapNotification(&arena_delta, parsed_delta.value.method.?, parsed_delta.value.params.?) orelse {
        arena_delta.deinit();
        return error.TestExpectedEqual;
    };
    defer delta_msg.deinit();

    var arena_completed = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed_completed = try std.json.parseFromSlice(RpcEnvelope, arena_completed.allocator(), completed_json, .{
        .ignore_unknown_fields = true,
    });
    var completed_msg = bridge.mapNotification(&arena_completed, parsed_completed.value.method.?, parsed_completed.value.params.?);
    if (completed_msg) |*msg| {
        defer msg.deinit();
        return error.TestExpectedEqual;
    }
    arena_completed.deinit();
}

const LiveSnapshotError = error{
    Timeout,
    UnexpectedEof,
    AuthRequired,
};

fn isAuthRequiredText(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "login") != null or
        std.mem.indexOf(u8, text, "authenticate") != null;
}

fn collectCodexSnapshot(allocator: Allocator, prompt: []const u8) ![]u8 {
    var bridge = CodexBridge.init(allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{ .resume_session_id = null, .model = null, .approval_policy = "never" });
    defer bridge.stop();

    const inputs = [_]UserInput{ .{ .type = "text", .text = prompt } };
    try bridge.sendPrompt(inputs[0..]);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var saw_delta = false;

    const deadline = std.time.milliTimestamp() + 60_000;
    while (true) {
        if (std.time.milliTimestamp() > deadline) return error.Timeout;
        var msg = (try readCodexMessageWithTimeout(&bridge, deadline)) orelse return error.UnexpectedEof;
        defer msg.deinit();

        switch (msg.event_type) {
            .agent_message_delta => {
                if (msg.getText()) |text| {
                    if (isAuthRequiredText(text)) return error.AuthRequired;
                    saw_delta = true;
                    try text_buf.appendSlice(allocator, text);
                }
            },
            .item_completed => {
                if (!saw_delta) {
                    if (msg.getText()) |text| {
                        if (isAuthRequiredText(text)) return error.AuthRequired;
                        try text_buf.appendSlice(allocator, text);
                    }
                }
            },
            .turn_completed => break,
            else => {},
        }
    }

    const normalized = try test_utils.normalizeSnapshotText(allocator, text_buf.items);
    defer allocator.free(normalized);

    return std.fmt.allocPrint(
        allocator,
        "engine: codex\ntext: {s}\n",
        .{normalized},
    );
}

fn readCodexMessageWithTimeout(bridge: *CodexBridge, deadline_ms: i64) !?CodexMessage {
    return bridge.readMessageWithTimeout(deadline_ms);
}

test "snapshot: Codex live prompt" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    const snapshot = try collectCodexSnapshot(testing.allocator, "Reply with exactly the single word BANJO.");
    defer testing.allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\engine: codex
        \\text: BANJO
        \\
    ).diff(snapshot, true);
}

const CodexTestError = error{
    Timeout,
    UnexpectedEof,
};

fn hasBufferedData(bridge: *CodexBridge) bool {
    return bridge.line_buffer.items.len > 0;
}

fn waitForReadable(bridge: *CodexBridge, timeout_ms: i32) !bool {
    const proc = bridge.process orelse return error.NotStarted;
    const stdout = proc.stdout orelse return error.NoStdout;
    return io_utils.waitForReadable(stdout.handle, timeout_ms);
}

fn waitForTurnCompleted(bridge: *CodexBridge, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;

    while (true) {
        var msg = (try bridge.readMessageWithTimeout(deadline)) orelse return error.UnexpectedEof;
        defer msg.deinit();
        if (msg.isTurnCompleted()) return;
    }
}

test "Codex app-server supports multi-turn prompts in one process" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{ .resume_session_id = null, .model = null, .approval_policy = "never" });
    defer bridge.stop();

    const first_inputs = [_]UserInput{ .{ .type = "text", .text = "say hello in one word" } };
    try bridge.sendPrompt(first_inputs[0..]);
    try waitForTurnCompleted(&bridge, 20000);

    const second_inputs = [_]UserInput{ .{ .type = "text", .text = "say goodbye in one word" } };
    try bridge.sendPrompt(second_inputs[0..]);
    try waitForTurnCompleted(&bridge, 20000);
}
