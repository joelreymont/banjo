const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config");
const constants = @import("constants.zig");
const log = std.log.scoped(.codex_bridge);
const executable = @import("executable.zig");
const io_utils = @import("io_utils.zig");
const test_utils = @import("test_utils.zig");
const auth_markers = @import("auth_markers.zig");
const core_types = @import("types.zig");
const byte_queue = @import("../util/byte_queue.zig");

const max_json_line_bytes: usize = 4 * 1024 * 1024;

// Models supported by Codex CLI
pub const models = [_]core_types.ModelInfo{
    .{ .id = "gpt-5.2-codex", .name = "gpt-5.2-codex", .desc = "Latest agentic coding model" },
    .{ .id = "gpt-5.1-codex-max", .name = "gpt-5.1-codex-max", .desc = "Deep and fast reasoning" },
    .{ .id = "gpt-5.1-codex-mini", .name = "gpt-5.1-codex-mini", .desc = "Cheaper, faster" },
    .{ .id = "gpt-5.2", .name = "gpt-5.2", .desc = "Latest frontier model" },
};

// Codex error info tags (matches codex_error_info field in TurnError)
pub const CodexErrorInfo = enum {
    context_window_exceeded,
    usage_limit_exceeded,
    http_connection_failed,
    response_stream_connection_failed,
    internal_server_error,
    unauthorized,
    bad_request,
    thread_rollback_failed,
    sandbox_error,
    response_stream_disconnected,
    response_too_many_failed_attempts,
    other,
    unknown,

    const tag_map = std.StaticStringMap(CodexErrorInfo).initComptime(.{
        .{ "contextWindowExceeded", .context_window_exceeded },
        .{ "usageLimitExceeded", .usage_limit_exceeded },
        .{ "httpConnectionFailed", .http_connection_failed },
        .{ "responseStreamConnectionFailed", .response_stream_connection_failed },
        .{ "internalServerError", .internal_server_error },
        .{ "unauthorized", .unauthorized },
        .{ "badRequest", .bad_request },
        .{ "threadRollbackFailed", .thread_rollback_failed },
        .{ "sandboxError", .sandbox_error },
        .{ "responseStreamDisconnected", .response_stream_disconnected },
        .{ "responseTooManyFailedAttempts", .response_too_many_failed_attempts },
        .{ "other", .other },
    });

    pub fn fromString(s: []const u8) CodexErrorInfo {
        return tag_map.get(s) orelse .unknown;
    }

    pub fn userMessage(self: CodexErrorInfo) ?[]const u8 {
        return switch (self) {
            .context_window_exceeded => "Context window exceeded. Try /compact to reduce history.",
            .usage_limit_exceeded => "API usage limit exceeded.",
            .unauthorized => "Authentication failed. Check API key.",
            .sandbox_error => "Sandbox execution error.",
            .response_stream_disconnected => "Connection lost. Retrying...",
            else => null,
        };
    }
};

pub const TurnError = struct {
    message: ?[]const u8 = null,
    codex_error_info: ?CodexErrorInfo = null,
    additional_details: ?[]const u8 = null,

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

    pub fn isMaxTurnError(self: TurnError) bool {
        return containsMaxTurnMarker(self.message) or
            containsMaxTurnMarker(self.additional_details);
    }

    pub fn isContextWindowExceeded(self: TurnError) bool {
        return self.codex_error_info == .context_window_exceeded;
    }

    // Custom JSON parser to handle codexErrorInfo tagged enum
    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!TurnError {
        _ = allocator;
        _ = options;
        if (source != .object) return .{};
        const obj = source.object;

        var result = TurnError{};
        if (obj.get("message")) |v| {
            if (v == .string) result.message = v.string;
        }
        if (obj.get("additionalDetails")) |v| {
            if (v == .string) result.additional_details = v.string;
        }
        // codexErrorInfo is a tagged enum: {"contextWindowExceeded": {}} or similar
        if (obj.get("codexErrorInfo")) |v| {
            if (v == .object) {
                var it = v.object.iterator();
                if (it.next()) |entry| {
                    result.codex_error_info = CodexErrorInfo.fromString(entry.key_ptr.*);
                }
            }
        }
        return result;
    }
};

pub const CodexMessage = struct {
    event_type: EventType,
    thread_id: ?[]const u8 = null,
    item: ?Item = null,
    text: ?[]const u8 = null,
    turn_status: ?[]const u8 = null,
    turn_error: ?TurnError = null,
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
        stream_error,
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
        raw: std.json.Value = .null,
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

const RpcError = struct {
    code: ?i64 = null,
    message: ?[]const u8 = null,
    data: ?std.json.Value = null,
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

const ThreadListParams = struct {
    limit: u32 = 20, // Fetch enough to find matching cwd
};

const ThreadSummary = struct {
    id: []const u8,
    cwd: []const u8,
};

const ThreadListResponse = struct {
    data: []const ThreadSummary,
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

const WorkspaceWriteSandboxPolicy = struct {
    type: []const u8 = "workspaceWrite",
    writableRoots: ?[]const []const u8 = null,
    networkAccess: ?bool = null,
    excludeSlashTmp: ?bool = null,
    excludeTmpdirEnvVar: ?bool = null,
};

const TurnStartParams = struct {
    threadId: []const u8,
    input: []const UserInput,
    cwd: ?[]const u8 = null,
    approvalPolicy: ?[]const u8 = null,
    sandboxPolicy: ?WorkspaceWriteSandboxPolicy = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    summary: ?[]const u8 = null,
};

const TurnRef = struct {
    id: []const u8,
    status: ?[]const u8 = null,
    @"error": ?TurnError = null,
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

const ErrorNotificationParams = struct {
    @"error": TurnError = .{},
    will_retry: bool = false,
    threadId: ?[]const u8 = null,
    turnId: ?[]const u8 = null,
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

const ResponsePayload = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
};

const ResponseError = struct {
    auth_required: bool = false,
};

const ResponseEntry = union(enum) {
    ok: ResponsePayload,
    err: ResponseError,
};

pub const CodexBridge = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    cwd: []const u8,
    stdout_file: ?std.fs.File = null,
    next_request_id: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    thread_id: ?[]const u8 = null,
    current_turn_id: ?[]const u8 = null,
    approval_policy: ?[]const u8 = null,
    saw_agent_delta: bool = false,
    saw_reasoning_delta: bool = false,
    pending_messages: std.ArrayList(CodexMessage) = .empty,
    pending_head: usize = 0,
    line_buffer: byte_queue.ByteQueue = .{},
    response_map: std.AutoHashMap(i64, ResponseEntry),
    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    write_mutex: std.Thread.Mutex = .{},
    reader_thread: ?std.Thread = null,
    reader_closed: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: Allocator, cwd: []const u8) CodexBridge {
        return .{
            .allocator = allocator,
            .cwd = cwd,
            .response_map = std.AutoHashMap(i64, ResponseEntry).init(allocator),
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
        self.clearResponses();
        self.pending_messages.deinit(self.allocator);
        self.line_buffer.deinit(self.allocator);
        self.response_map.deinit();
    }

    fn clearPendingMessages(self: *CodexBridge) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        for (self.pending_messages.items[self.pending_head..]) |*msg| {
            msg.deinit();
        }
        self.pending_messages.clearRetainingCapacity();
        self.pending_head = 0;
    }

    fn clearResponses(self: *CodexBridge) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        var it = self.response_map.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .ok => |payload| payload.arena.deinit(),
                .err => {},
            }
        }
        self.response_map.clearRetainingCapacity();
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
        resume_last: bool = false,
        model: ?[]const u8 = null,
        approval_policy: ?[]const u8 = null,
    };

    pub fn getThreadId(self: *CodexBridge) ?[]const u8 {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.thread_id;
    }

    pub fn start(self: *CodexBridge, opts: StartOptions) !void {
        // Clean up old process/thread if restarting after previous exit
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.process) |*proc| {
            _ = proc.wait() catch |err| {
                log.warn("Failed to wait for Codex process: {}", .{err});
            };
            self.process = null;
            self.stdout_file = null;
        }

        if (!CodexBridge.isAvailable()) {
            return error.CodexUnavailable;
        }

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
            _ = child.kill() catch |err| blk: {
                log.warn("Failed to kill Codex child: {}", .{err});
                break :blk std.process.Child.Term{ .Unknown = 0 };
            };
            _ = child.wait() catch |err| blk: {
                log.warn("Failed to wait for Codex child: {}", .{err});
                break :blk std.process.Child.Term{ .Unknown = 0 };
            };
        }
        self.process = child;
        self.stdout_file = self.process.?.stdout;
        self.line_buffer.clear();
        self.queue_mutex.lock();
        self.reader_closed = false;
        self.queue_mutex.unlock();
        self.stop_requested.store(false, .release);
        self.clearPendingMessages();
        self.clearResponses();
        self.startReaderThread() catch |err| {
            self.stop();
            return err;
        };

        self.approval_policy = opts.approval_policy;
        try self.initialize();

        if (opts.resume_last) {
            if (self.getMostRecentThread()) |tid| {
                defer self.allocator.free(tid);
                self.resumeThread(tid, opts.model) catch |err| {
                    log.warn("Failed to resume Codex thread ({s}): {}", .{ tid, err });
                    try self.startThread(opts.model);
                    return;
                };
                return;
            }
        }
        try self.startThread(opts.model);
    }

    fn startReaderThread(self: *CodexBridge) !void {
        if (self.reader_thread != null) return;
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
    }

    pub fn isAlive(self: *CodexBridge) bool {
        if (self.process == null) return false;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return !self.reader_closed;
    }

    /// Interrupt the current turn via JSON-RPC turn/interrupt
    pub fn interrupt(self: *CodexBridge) void {
        const thread_id = self.thread_id orelse {
            log.warn("Cannot interrupt: no thread_id", .{});
            return;
        };
        const turn_id = self.current_turn_id orelse {
            log.warn("Cannot interrupt: no turn_id", .{});
            return;
        };
        const request_id = self.nextRequestId();
        const params = TurnInterruptParams{
            .threadId = thread_id,
            .turnId = turn_id,
        };
        log.info("Sending turn/interrupt for turn {s}", .{turn_id});
        self.sendRequest(request_id, "turn/interrupt", params) catch |err| {
            log.warn("Failed to send turn/interrupt: {}", .{err});
        };
        // Response handled by readerMain; turn_completed with status=interrupted will follow
    }

    const TurnInterruptParams = struct {
        threadId: []const u8,
        turnId: []const u8,
    };

    pub fn stop(self: *CodexBridge) void {
        self.stop_requested.store(true, .release);
        if (self.process) |*proc| {
            _ = proc.kill() catch |err| switch (err) {
                error.AlreadyTerminated => {},
                else => log.warn("Failed to kill Codex process: {}", .{err}),
            };
            _ = proc.wait() catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("Failed to wait for Codex process: {}", .{err}),
            };
            self.process = null;
            self.stdout_file = null;
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.queue_mutex.lock();
        self.reader_closed = true;
        self.queue_mutex.unlock();
        self.queue_cond.broadcast();
        self.saw_agent_delta = false;
        self.saw_reasoning_delta = false;
        self.clearPendingMessages();
        self.clearResponses();
        self.line_buffer.clear();
        log.info("Stopped Codex", .{});
    }

    pub fn sendPrompt(self: *CodexBridge, inputs: []const UserInput) !void {
        const thread_id = self.thread_id orelse return error.NotStarted;
        const request_id = self.nextRequestId();

        var resolved_root: ?[]const u8 = null;
        defer if (resolved_root) |r| self.allocator.free(r);
        const root: []const u8 = if (std.fs.path.isAbsolute(self.cwd)) self.cwd else blk: {
            resolved_root = std.fs.cwd().realpathAlloc(self.allocator, self.cwd) catch |err| {
                log.err("Failed to resolve cwd '{s}': {}", .{ self.cwd, err });
                return error.InvalidCwd;
            };
            break :blk resolved_root.?;
        };

        var sandbox_policy = WorkspaceWriteSandboxPolicy{};
        var writable_roots: [1][]const u8 = undefined;
        writable_roots[0] = root;
        sandbox_policy.writableRoots = writable_roots[0..];

        const params = TurnStartParams{
            .threadId = thread_id,
            .input = inputs,
            .approvalPolicy = self.approval_policy,
            .sandboxPolicy = sandbox_policy,
        };

        try self.sendRequest(request_id, "turn/start", params);
        var response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const turn_id = extractTurnId(&response.arena, response.value) orelse {
            return error.InvalidResponse;
        };
        try self.setTurnId(turn_id);
        self.queue_mutex.lock();
        self.saw_agent_delta = false;
        self.saw_reasoning_delta = false;
        self.queue_mutex.unlock();
    }

    pub fn readMessage(self: *CodexBridge) !?CodexMessage {
        return self.popMessage(null);
    }

    pub fn readMessageWithTimeout(self: *CodexBridge, deadline_ms: i64) !?CodexMessage {
        return self.popMessage(deadline_ms);
    }

    fn popMessage(self: *CodexBridge, deadline_ms: ?i64) !?CodexMessage {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (true) {
            if (self.pending_head < self.pending_messages.items.len) {
                const msg = self.pending_messages.items[self.pending_head];
                self.pending_head += 1;
                if (self.pending_head >= self.pending_messages.items.len) {
                    self.pending_messages.clearRetainingCapacity();
                    self.pending_head = 0;
                }
                self.queue_cond.signal();
                return msg;
            }

            if (self.reader_closed) return null;

            if (deadline_ms) |deadline| {
                const now = std.time.milliTimestamp();
                if (now >= deadline) return error.Timeout;
                const slice_ms = io_utils.pollSliceMs(deadline, now);
                const timeout_ns: u64 = @as(u64, @intCast(slice_ms)) * std.time.ns_per_ms;
                self.queue_cond.timedWait(&self.queue_mutex, timeout_ns) catch |err| switch (err) {
                    error.Timeout => continue,
                };
            } else {
                self.queue_cond.wait(&self.queue_mutex);
            }
        }
    }

    fn enqueueMessage(self: *CodexBridge, msg: CodexMessage) void {
        self.queue_mutex.lock();
        while ((self.pending_messages.items.len - self.pending_head) >= constants.bridge_queue_max_messages) {
            if (self.stop_requested.load(.acquire)) {
                self.queue_mutex.unlock();
                var owned = msg;
                owned.deinit();
                return;
            }
            self.queue_cond.wait(&self.queue_mutex);
        }
        self.pending_messages.append(self.allocator, msg) catch |err| {
            log.err("Failed to queue Codex message: {}", .{err});
            var owned = msg;
            owned.deinit();
            self.queue_mutex.unlock();
            return;
        };
        self.queue_mutex.unlock();
        self.queue_cond.signal();
    }

    fn storeResponse(self: *CodexBridge, request_id: i64, entry: ResponseEntry) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        if (self.response_map.fetchRemove(request_id)) |existing| {
            switch (existing.value) {
                .ok => |payload| payload.arena.deinit(),
                .err => {},
            }
        }

        self.response_map.put(request_id, entry) catch |err| {
            switch (entry) {
                .ok => |payload| payload.arena.deinit(),
                .err => {},
            }
            log.err("Failed to store Codex response: {}", .{err});
            return;
        };
        self.queue_cond.broadcast();
    }

    fn readerMain(self: *CodexBridge) void {
        while (true) {
            if (self.stop_requested.load(.acquire)) break;
            var rpc_message = self.readRpcMessage() catch |err| {
                log.err("Codex reader failed: {}", .{err});
                break;
            } orelse break;
            var keep_arena = false;
            defer if (!keep_arena) rpc_message.arena.deinit();

            switch (rpc_message.kind) {
                .notification => {
                    const method = rpc_message.method orelse continue;
                    const params = rpc_message.params orelse continue;
                    const msg = self.mapNotification(&rpc_message.arena, method, params) catch |err| {
                        log.err("Codex notification parse failed: {}", .{err});
                        break;
                    };
                    if (msg) |resolved| {
                        keep_arena = true;
                        self.enqueueMessage(resolved);
                    }
                },
                .request => {
                    if (self.mapServerRequest(&rpc_message.arena, rpc_message)) |msg| {
                        keep_arena = true;
                        self.enqueueMessage(msg);
                    }
                },
                .response => {
                    const id_value = rpc_message.id orelse continue;
                    const id = parseRequestId(id_value) orelse {
                        log.warn("Codex response has invalid request id", .{});
                        continue;
                    };
                    const result = rpc_message.result orelse {
                        log.warn("Codex response missing result for request {d}", .{id});
                        continue;
                    };
                    keep_arena = true;
                    self.storeResponse(id, .{ .ok = .{ .arena = rpc_message.arena, .value = result } });
                },
                .err => {
                    const id_value = rpc_message.id orelse continue;
                    const id = parseRequestId(id_value) orelse {
                        log.warn("Codex error response has invalid request id", .{});
                        continue;
                    };
                    const err_value = rpc_message.err orelse continue;
                    const auth_required = isAuthRequiredError(&rpc_message.arena, err_value);
                    log.err("Codex app-server error response for request {d}", .{id});
                    self.storeResponse(id, .{ .err = .{ .auth_required = auth_required } });
                },
                .unknown => {},
            }
        }

        self.queue_mutex.lock();
        self.reader_closed = true;
        self.queue_mutex.unlock();
        self.queue_cond.broadcast();
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
            .sandbox = null, // Use Codex defaults
            .experimentalRawEvents = false,
        };
        try self.sendRequest(request_id, "thread/start", params);
        var response = try self.waitForResponse(request_id);
        defer response.arena.deinit();

        const thread_id = extractThreadId(&response.arena, response.value) orelse {
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

        const resumed_id = extractThreadId(&response.arena, response.value) orelse {
            return error.InvalidResponse;
        };
        try self.setThreadId(resumed_id);
    }

    /// Returns owned slice - caller must free with self.allocator
    fn getMostRecentThread(self: *CodexBridge) ?[]const u8 {
        const request_id = self.nextRequestId();
        self.sendRequest(request_id, "thread/list", ThreadListParams{}) catch |err| {
            log.warn("Failed to send thread/list request: {}", .{err});
            return null;
        };
        var response = self.waitForResponse(request_id) catch |err| {
            log.warn("Failed to get thread/list response: {}", .{err});
            return null;
        };
        defer response.arena.deinit();

        const parsed = std.json.parseFromValue(
            ThreadListResponse,
            response.arena.allocator(),
            response.value,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            log.warn("Failed to parse thread/list response: {}", .{err});
            return null;
        };

        // Resolve cwd to absolute path for comparison
        var abs_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_cwd = std.fs.cwd().realpath(self.cwd, &abs_cwd_buf) catch self.cwd;

        // Find most recent thread matching our cwd
        for (parsed.value.data) |thread| {
            // Normalize thread.cwd by stripping trailing /. if present
            var thread_cwd = thread.cwd;
            if (std.mem.endsWith(u8, thread_cwd, "/.")) {
                thread_cwd = thread_cwd[0 .. thread_cwd.len - 2];
            }
            if (std.mem.eql(u8, thread_cwd, abs_cwd)) {
                log.info("Found recent thread for cwd: {s}", .{thread.id});
                // Dupe before arena is freed
                return self.allocator.dupe(u8, thread.id) catch |err| {
                    log.warn("Failed to dupe thread id: {}", .{err});
                    return null;
                };
            }
        }
        return null;
    }

    fn setThreadId(self: *CodexBridge, thread_id: []const u8) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.thread_id) |existing| {
            self.allocator.free(existing);
        }
        self.thread_id = try self.allocator.dupe(u8, thread_id);
    }

    fn setTurnId(self: *CodexBridge, turn_id: []const u8) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
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
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try stdin.writeAll(json);
        try stdin.writeAll("\n");
    }

    fn waitForResponse(self: *CodexBridge, request_id: i64) !ResponsePayload {
        const deadline = std.time.milliTimestamp() + constants.rpc_timeout_ms;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (true) {
            if (self.response_map.fetchRemove(request_id)) |entry| {
                switch (entry.value) {
                    .ok => |payload| {
                        return payload;
                    },
                    .err => |err| {
                        if (err.auth_required) return error.AuthRequired;
                        return error.RequestFailed;
                    },
                }
            }

            if (self.reader_closed) return error.UnexpectedEof;

            const now = std.time.milliTimestamp();
            if (now >= deadline) return error.Timeout;
            const slice_ms = io_utils.pollSliceMs(deadline, now);
            const timeout_ns: u64 = @as(u64, @intCast(slice_ms)) * std.time.ns_per_ms;
            self.queue_cond.timedWait(&self.queue_mutex, timeout_ns) catch |err| switch (err) {
                error.Timeout => {},
            };
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

    fn parseRpcMessageLine(arena: *std.heap.ArenaAllocator, line: []const u8) !RpcMessage {
        const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
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
            .arena = arena.*,
            .id = envelope.id,
            .method = envelope.method,
            .params = envelope.params,
            .result = envelope.result,
            .err = envelope.@"error",
        };
    }

    fn readRpcMessage(self: *CodexBridge) !?RpcMessage {
        return self.readRpcMessageWithDeadline(null);
    }

    fn readRpcMessageWithDeadline(self: *CodexBridge, deadline_ms: ?i64) !?RpcMessage {
        _ = self.process orelse return error.NotStarted;

        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            var keep_arena = false;
            defer if (!keep_arena) arena.deinit();

            const stdout = self.stdout_file orelse return error.NoStdout;
            const line = (try io_utils.readLine(
                self.allocator,
                &self.line_buffer,
                stdout.deprecatedReader().any(),
                stdout.handle,
                deadline_ms,
                max_json_line_bytes,
            )) orelse return null;

            const msg = try parseRpcMessageLine(&arena, line);
            keep_arena = true;
            return msg;
        }
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
    ) !?CodexMessage {
        const kind = notificationKind(method);
        switch (kind) {
            .thread_started => {
                const parsed = try parseNotificationParams(arena, ThreadStartedParams, params);
                return CodexMessage{
                    .event_type = .thread_started,
                    .thread_id = parsed.thread.id,
                    .arena = arena.*,
                };
            },
            .turn_started => {
                _ = try parseNotificationParams(arena, TurnStartedParams, params);
                return CodexMessage{
                    .event_type = .turn_started,
                    .arena = arena.*,
                };
            },
            .turn_completed => {
                const parsed = try parseNotificationParams(arena, TurnCompletedParams, params);
                const turn_info = parsed.turn;
                const turn_id = if (turn_info) |turn|
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
                    .turn_status = if (turn_info) |turn| turn.status else null,
                    .turn_error = if (turn_info) |turn| turn.@"error" else null,
                    .arena = arena.*,
                };
            },
            .agent_message_delta => {
                const parsed = try parseNotificationParams(arena, ItemDeltaParams, params);
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const delta = parsed.delta orelse return null;
                self.queue_mutex.lock();
                self.saw_agent_delta = true;
                self.queue_mutex.unlock();
                return CodexMessage{
                    .event_type = .agent_message_delta,
                    .text = delta,
                    .arena = arena.*,
                };
            },
            .reasoning_summary_delta => {
                const parsed = try parseNotificationParams(arena, ItemDeltaParams, params);
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const delta = parsed.delta orelse return null;
                self.queue_mutex.lock();
                self.saw_reasoning_delta = true;
                self.queue_mutex.unlock();
                return CodexMessage{
                    .event_type = .reasoning_delta,
                    .text = delta,
                    .arena = arena.*,
                };
            },
            .reasoning_text_delta => {
                const parsed = try parseNotificationParams(arena, ItemDeltaParams, params);
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const delta = parsed.delta orelse return null;
                self.queue_mutex.lock();
                if (self.saw_reasoning_delta) {
                    self.queue_mutex.unlock();
                    return null;
                }
                self.saw_reasoning_delta = true;
                self.queue_mutex.unlock();
                return CodexMessage{
                    .event_type = .reasoning_delta,
                    .text = delta,
                    .arena = arena.*,
                };
            },
            .item_started, .item_completed => {
                const parsed = try parseNotificationParams(arena, ItemEventParams, params);
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                const item = try parseItem(arena, parsed.item);
                const event_type: CodexMessage.EventType = if (kind == .item_started) .item_started else .item_completed;

                if (event_type == .item_completed and item.kind == .agent_message) {
                    self.queue_mutex.lock();
                    const saw_agent = self.saw_agent_delta;
                    self.queue_mutex.unlock();
                    if (saw_agent) return null;
                }

                if (event_type == .item_completed and item.kind == .reasoning) {
                    self.queue_mutex.lock();
                    const saw_reasoning = self.saw_reasoning_delta;
                    self.queue_mutex.unlock();
                    if (saw_reasoning) return null;
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
            .stream_error => {
                const parsed = try parseNotificationParams(arena, ErrorNotificationParams, params);
                if (!self.matchesCurrentTurn(parsed.turnId)) return null;
                // If will_retry is true, this is transient - don't propagate as error
                if (parsed.will_retry) {
                    log.info("Codex transient error (will retry): {?s}", .{parsed.@"error".message});
                    return null;
                }
                return CodexMessage{
                    .event_type = .stream_error,
                    .turn_error = parsed.@"error",
                    .arena = arena.*,
                };
            },
            .unknown => return null,
        }
    }

    fn nextRequestId(self: *CodexBridge) i64 {
        return self.next_request_id.fetchAdd(1, .monotonic);
    }

    fn matchesCurrentTurn(self: *CodexBridge, turn_id: ?[]const u8) bool {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.current_turn_id) |current| {
            const id = turn_id orelse {
                log.warn("Codex event missing turnId (expected {s})", .{current});
                return false;
            };
            if (!std.mem.eql(u8, current, id)) {
                log.warn("Codex turn ID mismatch: expected {s}, got {s}", .{ current, id });
                return false;
            }
        }
        return true;
    }
};

fn parseI64Str(str: []const u8) ?i64 {
    if (str.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (str[0] == '-') {
        neg = true;
        i = 1;
        if (i == str.len) return null;
    }
    var acc: i64 = 0;
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (c < '0' or c > '9') return null;
        const digit: i64 = @intCast(c - '0');
        if (neg) {
            if (acc < @divTrunc(std.math.minInt(i64) + digit, 10)) return null;
            acc = acc * 10 - digit;
        } else {
            if (acc > @divTrunc(std.math.maxInt(i64) - digit, 10)) return null;
            acc = acc * 10 + digit;
        }
    }
    return acc;
}

fn parseRequestId(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .string => |str| parseI64Str(str),
        else => null,
    };
}

fn extractThreadId(arena: *std.heap.ArenaAllocator, value: std.json.Value) ?[]const u8 {
    const parsed = std.json.parseFromValueLeaky(ThreadStartResponse, arena.allocator(), value, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("Failed to parse thread start response: {}", .{err});
        return null;
    };
    return parsed.thread.id;
}

fn extractTurnId(arena: *std.heap.ArenaAllocator, value: std.json.Value) ?[]const u8 {
    const parsed = std.json.parseFromValueLeaky(TurnStartResponse, arena.allocator(), value, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("Failed to parse turn start response: {}", .{err});
        return null;
    };
    if (parsed.turn) |turn| return turn.id;
    return parsed.turnId;
}

fn parseItem(arena: *std.heap.ArenaAllocator, item: ItemData) !CodexMessage.Item {
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
            parsed.text = try joinStringLines(arena, summary_val.lines, "\n");
        }
        if (parsed.text == null) {
            if (item.content) |content_val| {
                parsed.text = try joinStringLines(arena, content_val.lines, "\n");
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
        .{ "error", .stream_error },
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

fn isAuthRequiredError(arena: *std.heap.ArenaAllocator, err_value: std.json.Value) bool {
    const parsed = std.json.parseFromValueLeaky(RpcError, arena.allocator(), err_value, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("Failed to parse Codex error: {}", .{err});
        return false;
    };
    const message = parsed.message orelse return false;
    return auth_markers.containsAuthMarker(message);
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

fn parseNotificationParams(arena: *std.heap.ArenaAllocator, comptime T: type, params: std.json.Value) !T {
    // Use parseFromValueLeaky since arena manages lifetime - no deinit needed
    return try std.json.parseFromValueLeaky(T, arena.allocator(), params, .{ .ignore_unknown_fields = true });
}

fn parseParams(allocator: Allocator, comptime T: type, value: std.json.Value) bool {
    const parsed = std.json.parseFromValue(T, allocator, value, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("Failed to parse {s} params: {}", .{ @typeName(T), err });
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
    stream_error,
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

fn joinStringLines(arena: *std.heap.ArenaAllocator, lines: []const []const u8, sep: []const u8) !?[]const u8 {
    if (lines.len == 0) return null;

    const allocator = arena.allocator();
    var total_len: usize = 0;
    for (lines) |line| {
        total_len += line.len;
    }
    total_len += sep.len * (lines.len - 1);

    const buf = try allocator.alloc(u8, total_len);
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
    var msg = (try bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?)) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const summary = .{ .text = msg.getText() };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.CodexMessage agent message delta parsing__struct_<^\d+$>
        \\  .text: ?[]const u8
        \\    "Hello"
    ).expectEqual(summary);
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
    var msg = (try bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?)) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const tool = msg.getToolResult().?;
    const summary = .{
        .id = tool.id,
        .content = tool.content,
        .exit_code = tool.exit_code,
    };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.CodexMessage command execution item parsing__struct_<^\d+$>
        \\  .id: []const u8
        \\    "item_2"
        \\  .content: ?[]const u8
        \\    "ok"
        \\  .exit_code: ?i64
        \\    0
    ).expectEqual(summary);
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
    var msg = (try bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?)) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const summary = .{ .session_id = msg.getSessionId() };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.CodexMessage thread started parsing__struct_<^\d+$>
        \\  .session_id: ?[]const u8
        \\    "thr_123"
    ).expectEqual(summary);
}

test "Codex sandbox policy encoded" {
    const inputs = [_]UserInput{.{ .type = "text", .text = "hi" }};
    var roots = [_][]const u8{"/tmp"};
    const policy = WorkspaceWriteSandboxPolicy{ .writableRoots = roots[0..] };
    const turn_params = TurnStartParams{
        .threadId = "thread-1",
        .input = &inputs,
        .sandboxPolicy = policy,
    };
    const turn_json = try std.json.Stringify.valueAlloc(testing.allocator, turn_params, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(turn_json);

    const thread_params = ThreadStartParams{
        .cwd = "/tmp",
        .sandbox = "workspace-write",
    };
    const thread_json = try std.json.Stringify.valueAlloc(testing.allocator, thread_params, .{
        .emit_null_optional_fields = false,
    });
    defer testing.allocator.free(thread_json);
    const combined = try std.fmt.allocPrint(
        testing.allocator,
        "turn: {s}\nthread: {s}\n",
        .{ turn_json, thread_json },
    );
    defer testing.allocator.free(combined);
    try (ohsnap{}).snap(@src(),
        \\turn: {"threadId":"thread-1","input":[{"type":"text","text":"hi"}],"sandboxPolicy":{"type":"workspaceWrite","writableRoots":["/tmp"]}}
        \\thread: {"cwd":"/tmp","sandbox":"workspace-write","experimentalRawEvents":false}
        \\
    ).diff(combined, true);
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
    var msg = (try bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?)) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const summary = .{ .thought = msg.getThought() };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.CodexMessage reasoning summary parsing__struct_<^\d+$>
        \\  .thought: ?[]const u8
        \\    "First
        \\Second"
    ).expectEqual(summary);
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
    var msg = (try bridge.mapNotification(&arena, parsed.value.method.?, parsed.value.params.?)) orelse {
        arena.deinit();
        return error.TestExpectedEqual;
    };
    defer msg.deinit();

    const tool = msg.getToolCall().?;
    const summary = .{ .id = tool.id, .command = tool.command };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.CodexMessage tool call parsing from item started__struct_<^\d+$>
        \\  .id: []const u8
        \\    "item_3"
        \\  .command: []const u8
        \\    "/bin/zsh -lc ls"
    ).expectEqual(summary);
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
    var delta_msg = (try bridge.mapNotification(&arena_delta, parsed_delta.value.method.?, parsed_delta.value.params.?)) orelse {
        arena_delta.deinit();
        return error.TestExpectedEqual;
    };
    defer delta_msg.deinit();

    var arena_completed = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed_completed = try std.json.parseFromSlice(RpcEnvelope, arena_completed.allocator(), completed_json, .{
        .ignore_unknown_fields = true,
    });
    var completed_msg = try bridge.mapNotification(&arena_completed, parsed_completed.value.method.?, parsed_completed.value.params.?);
    if (completed_msg) |*msg| {
        defer msg.deinit();
    }
    arena_completed.deinit();

    const summary = .{ .completed_present = completed_msg != null };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.CodexMessage item completed suppressed after agent delta__struct_<^\d+$>
        \\  .completed_present: bool = false
    ).expectEqual(summary);
}

test "Codex error auth detection" {
    const json =
        \\{"id":1,"error":{"code":401,"message":"Please login to authenticate"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const err_value = parsed.value.@"error" orelse return error.TestExpectedEqual;
    const summary = .{ .auth_required = isAuthRequiredError(&arena, err_value) };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.Codex error auth detection__struct_<^\d+$>
        \\  .auth_required: bool = true
    ).expectEqual(summary);
}

test "Codex error auth detection ignores non-auth message" {
    const json =
        \\{"id":2,"error":{"code":401,"message":"Request failed"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(RpcEnvelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const err_value = parsed.value.@"error" orelse return error.TestExpectedEqual;
    const summary = .{ .auth_required = isAuthRequiredError(&arena, err_value) };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.Codex error auth detection ignores non-auth message__struct_<^\d+$>
        \\  .auth_required: bool = false
    ).expectEqual(summary);
}

test "Codex auth marker detection for text" {
    const summary = .{
        .auth = isAuthRequiredText("Please login to continue"),
        .non_auth = isAuthRequiredText("All good"),
    };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.Codex auth marker detection for text__struct_<^\d+$>
        \\  .auth: bool = true
        \\  .non_auth: bool = false
    ).expectEqual(summary);
}

test "Codex parseRpcMessageLine detects auth error" {
    const line =
        \\{"id":5,"error":{"code":401,"message":"Please LOGIN to authenticate"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var msg = try CodexBridge.parseRpcMessageLine(&arena, line);
    defer msg.arena.deinit();

    const err_value = msg.err orelse return error.TestExpectedEqual;
    const summary = .{
        .kind = @tagName(msg.kind),
        .auth_required = isAuthRequiredError(&msg.arena, err_value),
    };
    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.test.Codex parseRpcMessageLine detects auth error__struct_<^\d+$>
        \\  .kind: [:0]const u8
        \\    "err"
        \\  .auth_required: bool = true
    ).expectEqual(summary);
}

test "perf: parseRpcMessageLine budget" {
    const line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    const iterations: usize = 2000;
    const budget_ns: u64 = 200 * std.time.ns_per_ms;

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        var msg = try CodexBridge.parseRpcMessageLine(&arena, line);
        msg.arena.deinit();
    }
    const elapsed = timer.read();
    try testing.expect(elapsed <= budget_ns);
}

const LiveSnapshotError = error{
    Timeout,
    UnexpectedEof,
    AuthRequired,
};

fn isAuthRequiredText(text: []const u8) bool {
    return auth_markers.containsAuthMarker(text);
}

fn collectCodexSnapshot(allocator: Allocator, prompt: []const u8) ![]u8 {
    var bridge = CodexBridge.init(allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{ .approval_policy = "never" });
    defer bridge.stop();

    const inputs = [_]UserInput{.{ .type = "text", .text = prompt }};
    try bridge.sendPrompt(inputs[0..]);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var saw_delta = false;

    const deadline = std.time.milliTimestamp() + constants.test_timeout_ms;
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
    return bridge.line_buffer.len() > 0;
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

    try bridge.start(.{ .approval_policy = "never" });
    defer bridge.stop();

    const first_inputs = [_]UserInput{.{ .type = "text", .text = "say hello in one word" }};
    try bridge.sendPrompt(first_inputs[0..]);
    try waitForTurnCompleted(&bridge, constants.live_turn_timeout_ms);

    const second_inputs = [_]UserInput{.{ .type = "text", .text = "say goodbye in one word" }};
    try bridge.sendPrompt(second_inputs[0..]);
    try waitForTurnCompleted(&bridge, constants.live_turn_timeout_ms);
}

fn waitForTurnStarted(bridge: *CodexBridge, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        var msg = (try bridge.readMessageWithTimeout(deadline)) orelse return error.UnexpectedEof;
        defer msg.deinit();
        if (msg.event_type == .turn_started) return;
        if (msg.isTurnCompleted()) return error.UnexpectedEof;
    }
}

const InterruptResult = struct {
    got_turn_completed: bool,
    status_is_interrupted: bool,
};

fn collectInterruptResult(bridge: *CodexBridge, timeout_ms: i64) !InterruptResult {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        var msg = (try bridge.readMessageWithTimeout(deadline)) orelse {
            return .{ .got_turn_completed = false, .status_is_interrupted = false };
        };
        defer msg.deinit();
        if (msg.isTurnCompleted()) {
            const is_interrupted = if (msg.turn_status) |s| std.mem.eql(u8, s, "interrupted") else false;
            return .{ .got_turn_completed = true, .status_is_interrupted = is_interrupted };
        }
    }
}

test "Codex interrupt stops turn and returns interrupted status" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{ .approval_policy = "never" });
    defer bridge.stop();

    // Start a prompt that will take a while to complete
    const inputs = [_]UserInput{.{ .type = "text", .text = "Write the numbers 1 through 200, one per line." }};
    try bridge.sendPrompt(inputs[0..]);

    // Wait for turn to actually start
    try waitForTurnStarted(&bridge, constants.live_stream_start_timeout_ms);

    // Small delay to ensure streaming has begun
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Send interrupt
    bridge.interrupt();

    // Collect result - should get turn_completed with interrupted status
    const result = try collectInterruptResult(&bridge, constants.live_turn_timeout_ms);

    try (ohsnap{}).snap(@src(),
        \\core.codex_bridge.InterruptResult
        \\  .got_turn_completed: bool = true
        \\  .status_is_interrupted: bool = true
    ).expectEqual(result);
}

test "Codex bridge handles interrupt then processes new prompt" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{ .approval_policy = "never" });
    defer bridge.stop();

    // First turn: start, interrupt
    const inputs = [_]UserInput{.{ .type = "text", .text = "Count from 1 to 50, one number per line." }};
    try bridge.sendPrompt(inputs[0..]);
    try waitForTurnStarted(&bridge, constants.live_stream_start_timeout_ms);
    std.Thread.sleep(100 * std.time.ns_per_ms);
    bridge.interrupt();

    // Wait for turn_completed with interrupted status
    const result = try collectInterruptResult(&bridge, constants.live_turn_timeout_ms);
    try testing.expect(result.got_turn_completed);
    try testing.expect(result.status_is_interrupted);

    // Bridge should still be alive (Codex doesn't exit on interrupt)
    try testing.expect(bridge.isAlive());

    // Send a new prompt and verify we get a response
    const inputs2 = [_]UserInput{.{ .type = "text", .text = "Say exactly: hello world" }};
    try bridge.sendPrompt(inputs2[0..]);

    var got_response = false;
    const deadline2 = std.time.milliTimestamp() + constants.live_snapshot_timeout_ms;
    while (std.time.milliTimestamp() < deadline2) {
        var msg = bridge.readMessageWithTimeout(deadline2) catch break orelse break;
        defer msg.deinit();
        if (msg.event_type == .agent_message_delta and msg.text != null) {
            got_response = true;
            break;
        }
    }

    try testing.expect(got_response);
}

test "Codex bridge restarts after process exit" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    // First session
    try bridge.start(.{ .approval_policy = "never" });
    try testing.expect(bridge.isAlive());

    // Force stop (simulates crash/exit)
    bridge.stop();
    try testing.expect(!bridge.isAlive());

    // Restart - this is the critical test
    try bridge.start(.{ .approval_policy = "never" });
    try testing.expect(bridge.isAlive());

    // Verify it works
    const inputs = [_]UserInput{.{ .type = "text", .text = "Say exactly: hello world" }};
    try bridge.sendPrompt(inputs[0..]);

    var got_response = false;
    const deadline = std.time.milliTimestamp() + constants.live_snapshot_timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        var msg = bridge.readMessageWithTimeout(deadline) catch break orelse break;
        defer msg.deinit();
        if (msg.event_type == .agent_message_delta and msg.text != null) {
            got_response = true;
            break;
        }
    }

    bridge.stop();
    try testing.expect(got_response);
}

test "Codex queue blocks when full" {
    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    var i: usize = 0;
    while (i < constants.bridge_queue_max_messages) : (i += 1) {
        const msg = CodexMessage{
            .event_type = .agent_message_delta,
            .text = "x",
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
        bridge.enqueueMessage(msg);
    }

    const Shared = struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };
    var state = Shared{};

    const extra = CodexMessage{
        .event_type = .agent_message_delta,
        .text = "x",
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    const ctx = struct {
        bridge: *CodexBridge,
        msg: CodexMessage,
        state: *Shared,
    }{ .bridge = &bridge, .msg = extra, .state = &state };

    const thread_fn = struct {
        fn run(arg: @TypeOf(ctx)) void {
            arg.state.started.store(true, .release);
            arg.bridge.enqueueMessage(arg.msg);
            arg.state.done.store(true, .release);
        }
    }.run;

    const thread = try std.Thread.spawn(.{}, thread_fn, .{ctx});
    defer thread.join();

    while (!state.started.load(.acquire)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    try testing.expect(!state.done.load(.acquire));

    var popped = (try bridge.popMessage(null)) orelse return error.TestUnexpectedResult;
    popped.deinit();

    bridge.queue_mutex.lock();
    const pending_len = bridge.pending_messages.items.len - bridge.pending_head;
    bridge.queue_mutex.unlock();

    try testing.expect(pending_len <= constants.bridge_queue_max_messages);
}

test "Codex resume_last resumes most recent thread for cwd" {
    // Tests that resume_last successfully finds and resumes a thread.
    // Does NOT test LLM memory - that's non-deterministic.
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!CodexBridge.isAvailable()) return error.SkipZigTest;

    var bridge = CodexBridge.init(testing.allocator, ".");
    defer bridge.deinit();

    // First session - create a thread
    try bridge.start(.{ .approval_policy = "never" });
    const inputs1 = [_]UserInput{.{ .type = "text", .text = "Say OK" }};
    try bridge.sendPrompt(inputs1[0..]);

    const deadline1 = std.time.milliTimestamp() + constants.live_turn_timeout_ms;
    while (std.time.milliTimestamp() < deadline1) {
        var msg = bridge.readMessageWithTimeout(deadline1) catch break orelse break;
        defer msg.deinit();
        if (msg.event_type == .turn_completed) break;
    }

    // Verify we have a thread_id from first session
    const first_thread_id = bridge.thread_id orelse {
        std.debug.print("No thread_id after first session\n", .{});
        return error.SkipZigTest;
    };
    const first_id_copy = try testing.allocator.dupe(u8, first_thread_id);
    defer testing.allocator.free(first_id_copy);

    bridge.stop();

    // Second session with resume_last - should find and resume the thread
    try bridge.start(.{ .approval_policy = "never", .resume_last = true });

    // Verify thread_id is set (resume worked)
    const resumed_thread_id = bridge.thread_id orelse {
        std.debug.print("No thread_id after resume_last\n", .{});
        return error.TestUnexpectedResult;
    };

    // The resumed thread should match our first session
    try testing.expectEqualStrings(first_id_copy, resumed_thread_id);

    bridge.stop();
}
