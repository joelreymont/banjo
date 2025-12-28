const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config");
const log = std.log.scoped(.codex_bridge);
const executable = @import("executable.zig");

pub const CodexMessage = struct {
    event_type: EventType,
    thread_id: ?[]const u8 = null,
    item: ?Item = null,
    text: ?[]const u8 = null,
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

const UserInput = struct {
    type: []const u8,
    text: []const u8,
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
    turn: TurnRef,
};

pub const CodexBridge = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    cwd: []const u8,
    stdout_reader: ?std.fs.File.Reader = null,
    stdout_buf: [64 * 1024]u8 = undefined,
    next_request_id: i64 = 1,
    thread_id: ?[]const u8 = null,
    current_turn_id: ?[]const u8 = null,
    saw_agent_delta: bool = false,
    saw_reasoning_delta: bool = false,
    pending_messages: std.ArrayList(CodexMessage) = .empty,

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
    }

    fn clearPendingMessages(self: *CodexBridge) void {
        for (self.pending_messages.items) |*msg| {
            msg.deinit();
        }
        self.pending_messages.clearRetainingCapacity();
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
    };

    pub fn getThreadId(self: *const CodexBridge) ?[]const u8 {
        return self.thread_id;
    }

    pub fn start(self: *CodexBridge, opts: StartOptions) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        const codex_path = findCodexBinary();
        log.info("Using codex binary: {s}", .{codex_path});

        try args.append(self.allocator, codex_path);
        try args.append(self.allocator, "app-server");

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
        if (self.process.?.stdout) |stdout| {
            self.stdout_reader = stdout.reader(&self.stdout_buf);
        } else {
            self.stdout_reader = null;
        }

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
            self.stdout_reader = null;
            self.saw_agent_delta = false;
            self.saw_reasoning_delta = false;
            self.clearPendingMessages();
            log.info("Stopped Codex", .{});
        }
    }

    pub fn sendPrompt(self: *CodexBridge, prompt: []const u8) !void {
        const thread_id = self.thread_id orelse return error.NotStarted;
        const request_id = self.nextRequestId();

        const inputs = [_]UserInput{
            .{ .type = "text", .text = prompt },
        };

        const params = TurnStartParams{
            .threadId = thread_id,
            .input = inputs[0..],
            .approvalPolicy = "never",
        };

        try self.sendRequest(request_id, "turn/start", params);
        const response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const turn_id = extractTurnId(response.value) orelse {
            return error.InvalidResponse;
        };
        try self.setTurnId(turn_id);
        self.saw_agent_delta = false;
        self.saw_reasoning_delta = false;
    }

    pub fn readMessage(self: *CodexBridge) !?CodexMessage {
        if (self.pending_messages.items.len > 0) {
            return self.pending_messages.orderedRemove(0);
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
                    if (self.mapNotification(method, params, &rpc_message.arena)) |msg| {
                        keep_arena = true;
                        return msg;
                    }
                },
                .request => {
                    try self.handleServerRequest(rpc_message);
                },
                .response, .err, .unknown => {},
            }
        }
    }

    fn initialize(self: *CodexBridge) !void {
        const request_id = self.nextRequestId();
        const params = InitializeParams{
            .clientInfo = .{
                .name = "banjo",
                .title = "Banjo ACP Agent",
                .version = config.version,
            },
        };
        try self.sendRequest(request_id, "initialize", params);
        const response = try self.waitForResponse(request_id);
        response.arena.deinit();
        try self.sendNotification("initialized");
    }

    fn startThread(self: *CodexBridge, model: ?[]const u8) !void {
        const request_id = self.nextRequestId();
        const params = ThreadStartParams{
            .model = model,
            .cwd = self.cwd,
            .approvalPolicy = "never",
            .experimentalRawEvents = false,
        };
        try self.sendRequest(request_id, "thread/start", params);
        const response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const thread_id = extractThreadId(response.value) orelse {
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
        const response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const resumed_id = extractThreadId(response.value) orelse {
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

    fn sendResponse(self: *CodexBridge, request_id: std.json.Value, result: anytype) !void {
        const payload = .{
            .id = request_id,
            .result = result,
        };
        try self.writeJsonLine(payload);
    }

    fn writeJsonLine(self: *CodexBridge, payload: anytype) !void {
        const proc = self.process orelse return error.NotStarted;
        const stdin = proc.stdin orelse return error.NoStdin;
        const json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);
        try stdin.writeAll(json);
        try stdin.writeAll("\n");
    }

    const ResponsePayload = struct {
        arena: std.heap.ArenaAllocator,
        value: std.json.Value,
    };

    fn waitForResponse(self: *CodexBridge, request_id: i64) !ResponsePayload {
        while (true) {
            var rpc_message = (try self.readRpcMessage()) orelse return error.UnexpectedEof;
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
                    if (self.mapNotification(method, params, &rpc_message.arena)) |msg| {
                        keep_arena = true;
                        try self.pending_messages.append(self.allocator, msg);
                    }
                },
                .request => {
                    try self.handleServerRequest(rpc_message);
                },
                .unknown => {},
            }
        }
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
        _ = self.process orelse return error.NotStarted;
        const reader = if (self.stdout_reader) |*stdout_reader| &stdout_reader.interface else return error.NoStdout;

        while (true) {
            const line = reader.takeDelimiter('\n') catch |e| switch (e) {
                error.ReadFailed => return null,
                error.StreamTooLong => return error.LineTooLong,
            } orelse return null;

            if (line.len == 0) continue;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();

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

    fn handleServerRequest(self: *CodexBridge, msg: RpcMessage) !void {
        const method = msg.method orelse return;
        const request_id = msg.id orelse return;

        if (approvalDecision(method)) |decision| {
            const response = .{ .decision = decision };
            try self.sendResponse(request_id, response);
            return;
        }

        log.warn("Unhandled Codex server request: {s}", .{method});
        const response = .{ .decision = "decline" };
        try self.sendResponse(request_id, response);
    }

    fn mapNotification(
        self: *CodexBridge,
        method: []const u8,
        params: std.json.Value,
        arena: *std.heap.ArenaAllocator,
    ) ?CodexMessage {
        if (params != .object) return null;
        const obj = params.object;

        const kind = notificationKind(method);
        switch (kind) {
            .thread_started => {
                if (obj.get("thread")) |thread_val| {
                    if (thread_val == .object) {
                        if (getString(thread_val.object, "id")) |thread_id| {
                            return CodexMessage{
                                .event_type = .thread_started,
                                .thread_id = thread_id,
                                .arena = arena.*,
                            };
                        }
                    }
                }
                return null;
            },
            .turn_started => {
                return CodexMessage{
                    .event_type = .turn_started,
                    .arena = arena.*,
                };
            },
            .turn_completed => {
                if (obj.get("turn")) |turn_val| {
                    if (turn_val == .object) {
                        if (getString(turn_val.object, "id")) |turn_id| {
                            if (self.current_turn_id) |current| {
                                if (!std.mem.eql(u8, current, turn_id)) {
                                    return null;
                                }
                            }
                            return CodexMessage{
                                .event_type = .turn_completed,
                                .thread_id = getString(obj, "threadId"),
                                .arena = arena.*,
                            };
                        }
                    }
                }
                return null;
            },
            .agent_message_delta => {
                if (!self.matchesCurrentTurn(obj)) return null;
                if (getString(obj, "delta")) |delta| {
                    self.saw_agent_delta = true;
                    return CodexMessage{
                        .event_type = .agent_message_delta,
                        .text = delta,
                        .arena = arena.*,
                    };
                }
                return null;
            },
            .reasoning_summary_delta => {
                if (!self.matchesCurrentTurn(obj)) return null;
                if (getString(obj, "delta")) |delta| {
                    self.saw_reasoning_delta = true;
                    return CodexMessage{
                        .event_type = .reasoning_delta,
                        .text = delta,
                        .arena = arena.*,
                    };
                }
                return null;
            },
            .reasoning_text_delta => {
                if (self.saw_reasoning_delta) return null;
                if (!self.matchesCurrentTurn(obj)) return null;
                if (getString(obj, "delta")) |delta| {
                    self.saw_reasoning_delta = true;
                    return CodexMessage{
                        .event_type = .reasoning_delta,
                        .text = delta,
                        .arena = arena.*,
                    };
                }
                return null;
            },
            .item_started, .item_completed => {
                if (!self.matchesCurrentTurn(obj)) return null;

                const item_val = obj.get("item") orelse return null;
                const item = parseItem(arena.allocator(), item_val) orelse return null;
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

    fn matchesCurrentTurn(self: *CodexBridge, obj: std.json.ObjectMap) bool {
        if (self.current_turn_id) |current| {
            if (getString(obj, "turnId")) |turn_id| {
                return std.mem.eql(u8, current, turn_id);
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

fn extractThreadId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const thread_val = value.object.get("thread") orelse return null;
    if (thread_val != .object) return null;
    return getString(thread_val.object, "id");
}

fn extractTurnId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const turn_val = value.object.get("turn") orelse return null;
    if (turn_val != .object) return null;
    return getString(turn_val.object, "id");
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn parseItem(allocator: Allocator, value: std.json.Value) ?CodexMessage.Item {
    if (value != .object) return null;
    const obj = value.object;
    const item_type = getString(obj, "type") orelse return null;
    const item_id = getString(obj, "id") orelse return null;
    const kind = parseItemKind(item_type);

    var item = CodexMessage.Item{
        .id = item_id,
        .kind = kind,
    };

    if (kind == .agent_message) {
        item.text = getString(obj, "text");
        return item;
    }

    if (kind == .reasoning) {
        if (obj.get("summary")) |summary_val| {
            item.text = joinStringArray(allocator, summary_val, "\n");
        }
        if (item.text == null) {
            if (obj.get("content")) |content_val| {
                item.text = joinStringArray(allocator, content_val, "\n");
            }
        }
        return item;
    }

    if (kind == .command_execution) {
        item.command = getString(obj, "command");
        item.aggregated_output = getString(obj, "aggregatedOutput") orelse getString(obj, "aggregated_output");
        item.exit_code = getInt(obj, "exitCode") orelse getInt(obj, "exit_code");
        item.status = getString(obj, "status");
        return item;
    }

    return item;
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
        .{ "item/completed", .item_completed },
    });
    return map.get(method) orelse .unknown;
}

fn approvalDecision(method: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "item/commandExecution/requestApproval", "accept" },
        .{ "item/fileChange/requestApproval", "accept" },
        .{ "applyPatchApproval", "approved" },
        .{ "execCommandApproval", "approved" },
    });
    return map.get(method);
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

fn joinStringArray(allocator: Allocator, value: std.json.Value, sep: []const u8) ?[]const u8 {
    if (value != .array) return null;
    if (value.array.items.len == 0) return null;

    var total_len: usize = 0;
    var count: usize = 0;
    for (value.array.items) |item| {
        if (item == .string) {
            total_len += item.string.len;
            count += 1;
        }
    }
    if (count == 0) return null;
    total_len += sep.len * (count - 1);

    const buf = allocator.alloc(u8, total_len) catch return null;
    var offset: usize = 0;
    var first = true;
    for (value.array.items) |item| {
        if (item != .string) continue;
        if (!first) {
            std.mem.copyForwards(u8, buf[offset..][0..sep.len], sep);
            offset += sep.len;
        }
        first = false;
        std.mem.copyForwards(u8, buf[offset..][0..item.string.len], item.string);
        offset += item.string.len;
    }
    return buf;
}

// Tests
const testing = std.testing;

test "CodexMessage agent message delta parsing" {
    const json =
        \\{"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"Hello"}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    var bridge = CodexBridge.init(testing.allocator, ".");
    var msg = bridge.mapNotification(parsed.value.method.?, parsed.value.params.?, &arena) orelse {
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
    var msg = bridge.mapNotification(parsed.value.method.?, parsed.value.params.?, &arena) orelse {
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
    var msg = bridge.mapNotification(parsed.value.method.?, parsed.value.params.?, &arena) orelse {
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
    var msg = bridge.mapNotification(parsed.value.method.?, parsed.value.params.?, &arena) orelse {
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
    var msg = bridge.mapNotification(parsed.value.method.?, parsed.value.params.?, &arena) orelse {
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
    var delta_msg = bridge.mapNotification(parsed_delta.value.method.?, parsed_delta.value.params.?, &arena_delta) orelse {
        arena_delta.deinit();
        return error.TestExpectedEqual;
    };
    defer delta_msg.deinit();

    var arena_completed = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed_completed = try std.json.parseFromSlice(RpcEnvelope, arena_completed.allocator(), completed_json, .{
        .ignore_unknown_fields = true,
    });
    var completed_msg = bridge.mapNotification(parsed_completed.value.method.?, parsed_completed.value.params.?, &arena_completed);
    if (completed_msg) |*msg| {
        defer msg.deinit();
        return error.TestExpectedEqual;
    }
    arena_completed.deinit();
}

const CodexTestError = error{
    Timeout,
    UnexpectedEof,
};

fn hasBufferedData(bridge: *CodexBridge) bool {
    if (bridge.stdout_reader) |*reader| {
        return reader.interface.seek < reader.interface.end;
    }
    return false;
}

fn waitForReadable(bridge: *CodexBridge, timeout_ms: i32) !bool {
    const proc = bridge.process orelse return error.NotStarted;
    const stdout = proc.stdout orelse return error.NoStdout;

    var fds = [_]std.posix.pollfd{
        .{
            .fd = stdout.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const count = try std.posix.poll(&fds, timeout_ms);
    if (count == 0) return false;
    if ((fds[0].revents & std.posix.POLL.HUP) != 0) return error.UnexpectedEof;
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

fn waitForTurnCompleted(bridge: *CodexBridge, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;

    while (true) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return error.Timeout;

        if (hasBufferedData(bridge)) {
            var msg = (try bridge.readMessage()) orelse return error.UnexpectedEof;
            defer msg.deinit();
            if (msg.isTurnCompleted()) return;
            continue;
        }

        const remaining_ms = deadline - now;
        const slice_ms: i32 = @intCast(@min(@as(i64, 200), remaining_ms));
        const readable = try waitForReadable(bridge, slice_ms);
        if (!readable) continue;
        var msg = (try bridge.readMessage()) orelse return error.UnexpectedEof;
        defer msg.deinit();
        if (msg.isTurnCompleted()) return;
    }
}

test "Codex app-server supports multi-turn prompts in one process" {
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{ .resume_session_id = null, .model = null });
    defer bridge.stop();

    try bridge.sendPrompt("say hello in one word");
    try waitForTurnCompleted(&bridge, 20000);

    try bridge.sendPrompt("say goodbye in one word");
    try waitForTurnCompleted(&bridge, 20000);
}
