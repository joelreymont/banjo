const std = @import("std");
const permission_mode = @import("../core/permission_mode.zig");

pub const ProtocolVersion = 1;

// =============================================================================
// Initialize
// =============================================================================

pub const InitializeRequest = struct {
    protocolVersion: i32,
    clientCapabilities: ClientCapabilities,
    clientInfo: ClientInfo,
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const ClientCapabilities = struct {
    fs: ?FsCapabilities = null,
    terminal: ?bool = null,
};

pub const FsCapabilities = struct {
    readTextFile: ?bool = null,
    writeTextFile: ?bool = null,
};

pub const InitializeResponse = struct {
    protocolVersion: i32 = ProtocolVersion,
    agentInfo: AgentInfo,
    agentCapabilities: AgentCapabilities,
    authMethods: []const AuthMethod,
};

pub const AgentInfo = struct {
    name: []const u8,
    title: []const u8,
    version: []const u8,
};

pub const AgentCapabilities = struct {
    promptCapabilities: PromptCapabilities,
    mcpCapabilities: ?McpCapabilities = null,
    sessionCapabilities: ?SessionCapabilities = null,
    loadSession: bool = false,
};

pub const PromptCapabilities = struct {
    image: bool = false,
    audio: bool = false,
    embeddedContext: bool = false,
};

pub const McpCapabilities = struct {
    http: bool = false,
    sse: bool = false,
};

pub const SessionCapabilities = struct {};

pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const EmptyResponse = struct {};

pub const AuthenticateResponse = EmptyResponse;

// =============================================================================
// Session
// =============================================================================

pub const NewSessionRequest = struct {
    cwd: []const u8,
    _meta: ?std.json.Value = null,
};

pub const NewSessionResponse = struct {
    sessionId: []const u8,
    configOptions: ?[]const SessionConfigOption = null,
    models: ?SessionModelState = null,
    modes: ?SessionModeState = null,

    // Custom serializer: only output fields Zed's ACP client supports
    pub fn jsonStringify(self: NewSessionResponse, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sessionId");
        try jw.write(self.sessionId);
        if (self.modes) |modes| {
            try jw.objectField("modes");
            try jw.write(modes);
        }
        // Note: configOptions and models not yet supported by Zed ACP
        try jw.endObject();
    }
};

pub const SessionConfigOptionType = enum {
    select,
};

pub const SessionConfigSelectOption = struct {
    value: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,

    pub fn jsonStringify(self: SessionConfigSelectOption, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("value");
        try jw.write(self.value);
        try jw.objectField("name");
        try jw.write(self.name);
        if (self.description) |val| {
            try jw.objectField("description");
            try jw.write(val);
        }
        try jw.endObject();
    }
};

pub const SessionConfigOption = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    type: SessionConfigOptionType,
    currentValue: []const u8,
    options: []const SessionConfigSelectOption,
};

pub const SessionModel = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const SessionModelState = struct {
    availableModels: []const SessionModel,
    currentModelId: []const u8,
};

pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8,
};

pub const ResumeSessionRequest = struct {
    sessionId: []const u8,
    cwd: []const u8,
    _meta: ?std.json.Value = null,
};

pub const ResumeSessionResponse = struct {
    sessionId: []const u8,
};

// =============================================================================
// Prompt
// =============================================================================

pub const EmbeddedResourceResource = struct {
    uri: []const u8,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    size: ?i64 = null,
    resource: ?EmbeddedResourceResource = null,
};

pub const PromptRequest = struct {
    sessionId: []const u8,
    prompt: []const ContentBlock,
};

pub const PromptResponse = struct {
    stopReason: StopReason,
};

pub const StopReason = enum {
    end_turn,
    cancelled,
    max_tokens,
    max_turn_requests,
    auth_required,
    refusal,
};

// =============================================================================
// Session Update (Notification)
// =============================================================================

/// Wire format: { "sessionId": "...", "update": { "sessionUpdate": "...", ... } }
pub const SessionUpdate = struct {
    sessionId: []const u8,
    update: Update,

    pub const UpdateType = enum {
        agent_message_chunk,
        user_message_chunk,
        agent_thought_chunk,
        tool_call,
        tool_call_update,
        plan,
        available_commands_update,
        current_mode_update,
        current_model_update,
    };

    pub const ContentChunk = ContentBlock;

    pub const ToolCallContent = struct {
        type: []const u8,
        content: ?ContentBlock = null,
        terminalId: ?[]const u8 = null,
        path: ?[]const u8 = null,
        oldText: ?[]const u8 = null,
        newText: ?[]const u8 = null,
    };

    pub const ToolCallLocation = struct {
        path: []const u8,
        line: ?u32 = null,
    };

    pub const ToolKind = enum {
        read,
        edit,
        write,
        delete,
        move,
        search,
        execute,
        think,
        fetch,
        switch_mode,
        other,
    };

    pub const ToolCallStatus = enum {
        pending,
        in_progress,
        completed,
        failed,
    };

    pub const PlanEntry = struct {
        id: []const u8,
        content: []const u8,
        status: PlanStatus,
    };

    pub const PlanStatus = enum {
        pending,
        in_progress,
        completed,
    };

    pub fn jsonStringify(self: SessionUpdate, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sessionId");
        try jw.write(self.sessionId);
        try jw.objectField("update");
        try jw.write(self.update);
        try jw.endObject();
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!SessionUpdate {
        return std.json.parseFromValue(SessionUpdate, allocator, source, options);
    }

    pub const Update = struct {
        sessionUpdate: UpdateType,
        content: ?ContentChunk = null,
        toolContent: ?[]const ToolCallContent = null,
        toolCallId: ?[]const u8 = null,
        title: ?[]const u8 = null,
        kind: ?ToolKind = null,
        status: ?ToolCallStatus = null,
        rawInput: ?std.json.Value = null,
        rawOutput: ?std.json.Value = null,
        locations: ?[]const ToolCallLocation = null,
        entries: ?[]const PlanEntry = null,
        currentModeId: ?[]const u8 = null,
        currentModelId: ?[]const u8 = null,
        availableCommands: ?[]const SlashCommand = null,

        pub fn jsonStringify(self: Update, jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("sessionUpdate");
            try jw.write(self.sessionUpdate);
            if (self.content) |val| {
                try jw.objectField("content");
                try jw.write(val);
            } else if (self.toolContent) |val| {
                try jw.objectField("content");
                try jw.write(val);
            }
            if (self.toolCallId) |val| {
                try jw.objectField("toolCallId");
                try jw.write(val);
            }
            if (self.title) |val| {
                try jw.objectField("title");
                try jw.write(val);
            }
            if (self.kind) |val| {
                try jw.objectField("kind");
                try jw.write(val);
            }
            if (self.status) |val| {
                try jw.objectField("status");
                try jw.write(val);
            }
            if (self.rawInput) |val| {
                try jw.objectField("rawInput");
                try val.jsonStringify(jw);
            }
            if (self.rawOutput) |val| {
                try jw.objectField("rawOutput");
                try val.jsonStringify(jw);
            }
            if (self.locations) |val| {
                try jw.objectField("locations");
                try jw.write(val);
            }
            if (self.entries) |val| {
                try jw.objectField("entries");
                try jw.write(val);
            }
            if (self.currentModeId) |val| {
                try jw.objectField("currentModeId");
                try jw.write(val);
            }
            if (self.currentModelId) |val| {
                try jw.objectField("currentModelId");
                try jw.write(val);
            }
            if (self.availableCommands) |val| {
                try jw.objectField("availableCommands");
                try jw.write(val);
            }
            try jw.endObject();
        }
    };

    // Convenience constructors
    pub fn textChunk(session_id: []const u8, text: []const u8) SessionUpdate {
        return .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = .agent_message_chunk,
                .content = .{ .type = "text", .text = text },
            },
        };
    }

    pub fn toolCall(session_id: []const u8, tool_call_id: []const u8, title: []const u8, kind: ToolKind) SessionUpdate {
        return .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = .tool_call,
                .toolCallId = tool_call_id,
                .title = title,
                .kind = kind,
                .status = .pending,
            },
        };
    }
};

pub const ToolCallUpdate = struct {
    toolCallId: []const u8,
    title: ?[]const u8 = null,
    kind: ?SessionUpdate.ToolKind = null,
    status: ?SessionUpdate.ToolCallStatus = null,
    rawInput: ?std.json.Value = null,
    rawOutput: ?std.json.Value = null,
    content: ?[]const SessionUpdate.ToolCallContent = null,
    locations: ?[]const SessionUpdate.ToolCallLocation = null,
};

// =============================================================================
// Cancel
// =============================================================================

pub const CancelNotification = struct {
    sessionId: []const u8,
};

// =============================================================================
// Permission Request
// =============================================================================

pub const PermissionRequest = struct {
    sessionId: []const u8,
    toolCall: ToolCallUpdate,
    options: []const PermissionOption,
};

pub const PermissionOption = struct {
    kind: PermissionOptionKind,
    name: []const u8,
    optionId: []const u8,
};

pub const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,
};

pub const PermissionResponse = struct {
    outcome: PermissionOutcome,
};

pub const PermissionOutcome = struct {
    outcome: PermissionOutcomeKind,
    optionId: ?[]const u8 = null,
};

pub const PermissionOutcomeKind = enum {
    selected,
    cancelled,
};

// =============================================================================
// File System (Agent -> Client)
// =============================================================================

pub const ReadTextFileRequest = struct {
    sessionId: []const u8,
    path: []const u8,
    line: ?u32 = null,
    limit: ?u32 = null,
};

pub const ReadTextFileResponse = struct {
    content: []const u8,
};

pub const WriteTextFileRequest = struct {
    sessionId: []const u8,
    path: []const u8,
    content: []const u8,
};

pub const WriteTextFileResponse = struct {};

// =============================================================================
// Terminal (Agent -> Client)
// =============================================================================

pub const CreateTerminalRequest = struct {
    sessionId: []const u8,
    command: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const EnvVariable = null,
    cwd: ?[]const u8 = null,
    outputByteLimit: ?u64 = null,
};

pub const CreateTerminalResponse = struct {
    terminalId: []const u8,
};

pub const TerminalOutputRequest = struct {
    sessionId: []const u8,
    terminalId: []const u8,
};

pub const TerminalOutputResponse = struct {
    output: []const u8,
    exitStatus: ?TerminalExitStatus = null,
    truncated: bool = false,
};

pub const TerminalExitStatus = struct {
    exitCode: ?u32 = null,
    signal: ?[]const u8 = null,
};

pub const WaitForTerminalExitRequest = struct {
    sessionId: []const u8,
    terminalId: []const u8,
};

pub const WaitForTerminalExitResponse = struct {
    exitCode: ?u32 = null,
    signal: ?[]const u8 = null,
};

pub const TerminalKillRequest = struct {
    sessionId: []const u8,
    terminalId: []const u8,
};

pub const TerminalReleaseRequest = struct {
    sessionId: []const u8,
    terminalId: []const u8,
};

pub const EnvVariable = struct {
    name: []const u8,
    value: []const u8,
};

// =============================================================================
// Session Modes
// =============================================================================

pub const SessionMode = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const SessionModeState = struct {
    availableModes: []const SessionMode,
    currentModeId: []const u8,
};

// =============================================================================
// Set Mode
// =============================================================================

pub const SetModeRequest = struct {
    sessionId: []const u8,
    modeId: []const u8,
};

pub const SetModeResponse = EmptyResponse;

// =============================================================================
// Set Model
// =============================================================================

pub const SetModelRequest = struct {
    sessionId: []const u8,
    modelId: []const u8,
};

pub const SetModelResponse = EmptyResponse;

// =============================================================================
// Set Config
// =============================================================================

pub const SetConfigOptionRequest = struct {
    sessionId: []const u8,
    configId: []const u8,
    value: []const u8,
};

pub const SetConfigOptionResponse = struct {
    configOptions: []const SessionConfigOption,
};

pub const PermissionMode = permission_mode.PermissionMode;

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

fn jsonAlloc(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{ .emit_null_optional_fields = false });
}

test "SessionUpdate serialization" {
    const update = SessionUpdate.textChunk("sess-123", "Hello world");
    const json = try jsonAlloc(testing.allocator, update);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"sessionId":"sess-123","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello world"}}}
    ).diff(json, true);
}

test "SessionUpdate tool_call serialization" {
    const update = SessionUpdate.toolCall("sess-123", "tc-456", "Read file", .read);
    const json = try jsonAlloc(testing.allocator, update);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"sessionId":"sess-123","update":{"sessionUpdate":"tool_call","toolCallId":"tc-456","title":"Read file","kind":"read","status":"pending"}}
    ).diff(json, true);
}

test "PermissionRequest serialization" {
    const req = PermissionRequest{
        .sessionId = "sess-123",
        .toolCall = .{
            .toolCallId = "tc-456",
            .title = "Run bash",
            .kind = .execute,
            .status = .pending,
        },
        .options = &.{
            .{ .kind = .allow_once, .name = "Allow", .optionId = "opt-1" },
            .{ .kind = .reject_once, .name = "Reject", .optionId = "opt-2" },
        },
    };
    const json = try jsonAlloc(testing.allocator, req);
    defer testing.allocator.free(json);

    const summary = .{
        .has_session = std.mem.indexOf(u8, json, "sess-123") != null,
        .has_tool_call = std.mem.indexOf(u8, json, "tc-456") != null,
        .has_options = std.mem.indexOf(u8, json, "allow_once") != null,
    };
    try (ohsnap{}).snap(@src(),
        \\acp.protocol.test.PermissionRequest serialization__struct_<^\d+$>
        \\  .has_session: bool = true
        \\  .has_tool_call: bool = true
        \\  .has_options: bool = true
    ).expectEqual(summary);
}

test "StopReason serialization" {
    const end_turn = try jsonAlloc(testing.allocator, StopReason.end_turn);
    defer testing.allocator.free(end_turn);
    const cancelled = try jsonAlloc(testing.allocator, StopReason.cancelled);
    defer testing.allocator.free(cancelled);
    const max_tokens = try jsonAlloc(testing.allocator, StopReason.max_tokens);
    defer testing.allocator.free(max_tokens);
    const auth_required = try jsonAlloc(testing.allocator, StopReason.auth_required);
    defer testing.allocator.free(auth_required);

    try testing.expectEqualStrings("\"end_turn\"", end_turn);
    try testing.expectEqualStrings("\"cancelled\"", cancelled);
    try testing.expectEqualStrings("\"max_tokens\"", max_tokens);
    try testing.expectEqualStrings("\"auth_required\"", auth_required);
}

test "ToolCallStatus serialization" {
    const pending_json = try jsonAlloc(testing.allocator, SessionUpdate.ToolCallStatus.pending);
    defer testing.allocator.free(pending_json);
    const in_progress_json = try jsonAlloc(testing.allocator, SessionUpdate.ToolCallStatus.in_progress);
    defer testing.allocator.free(in_progress_json);
    const completed_json = try jsonAlloc(testing.allocator, SessionUpdate.ToolCallStatus.completed);
    defer testing.allocator.free(completed_json);
    const failed_json = try jsonAlloc(testing.allocator, SessionUpdate.ToolCallStatus.failed);
    defer testing.allocator.free(failed_json);

    // Verify enum values serialize to expected JSON strings
    try testing.expectEqualStrings("\"pending\"", pending_json);
    try testing.expectEqualStrings("\"in_progress\"", in_progress_json);
    try testing.expectEqualStrings("\"completed\"", completed_json);
    try testing.expectEqualStrings("\"failed\"", failed_json);
}

test "ContentBlock text variant" {
    const block = ContentBlock{ .type = "text", .text = "Hello" };
    const json = try jsonAlloc(testing.allocator, block);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"type":"text","text":"Hello"}
    ).diff(json, true);
}

test "ContentBlock image variant" {
    const block = ContentBlock{ .type = "image", .data = "base64data", .mimeType = "image/png" };
    const json = try jsonAlloc(testing.allocator, block);
    defer testing.allocator.free(json);

    const summary = .{
        .has_type = std.mem.indexOf(u8, json, "\"type\":\"image\"") != null,
        .has_data = std.mem.indexOf(u8, json, "base64data") != null,
        .has_mime = std.mem.indexOf(u8, json, "image/png") != null,
    };
    try (ohsnap{}).snap(@src(),
        \\acp.protocol.test.ContentBlock image variant__struct_<^\d+$>
        \\  .has_type: bool = true
        \\  .has_data: bool = true
        \\  .has_mime: bool = true
    ).expectEqual(summary);
}
