const std = @import("std");

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
};

pub const PromptCapabilities = struct {
    image: bool = false,
    embeddedContext: bool = false,
};

pub const McpCapabilities = struct {
    http: bool = false,
    sse: bool = false,
};

pub const SessionCapabilities = struct {
    fork: ?struct {} = null,
    @"resume": ?struct {} = null,
};

pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
};

// =============================================================================
// Session
// =============================================================================

pub const NewSessionRequest = struct {
    cwd: []const u8,
    mcpServers: ?std.json.Value = null,
    _meta: ?std.json.Value = null,
};

pub const NewSessionResponse = struct {
    sessionId: []const u8,
    availableCommands: ?[]const SlashCommand = null,
};

pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8,
};

pub const ResumeSessionRequest = struct {
    sessionId: []const u8,
    cwd: []const u8,
    mcpServers: ?std.json.Value = null,
    _meta: ?std.json.Value = null,
};

pub const ResumeSessionResponse = struct {
    sessionId: []const u8,
};

// =============================================================================
// Prompt
// =============================================================================

pub const PromptRequest = struct {
    sessionId: []const u8,
    prompt: []const PromptChunk,
};

pub const PromptChunk = struct {
    type: ChunkType,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
    uri: ?[]const u8 = null,

    pub const ChunkType = enum {
        text,
        image,
        resource,
        resource_link,
    };
};

pub const PromptResponse = struct {
    stopReason: StopReason,
};

pub const StopReason = enum {
    end_turn,
    cancelled,
    max_turn_requests,
};

// =============================================================================
// Session Update (Notification)
// =============================================================================

/// Wire format: { "sessionId": "...", "update": { "sessionUpdate": "...", ... } }
pub const SessionUpdate = struct {
    sessionId: []const u8,
    update: Update,

    /// The update payload with sessionUpdate discriminator
    pub const Update = struct {
        sessionUpdate: UpdateType,
        // Content for message chunks
        content: ?ContentChunk = null,
        // Tool call fields
        toolCallId: ?[]const u8 = null,
        title: ?[]const u8 = null,
        kind: ?ToolKind = null,
        status: ?ToolCallStatus = null,
        rawInput: ?std.json.Value = null,
        // Plan fields
        entries: ?[]const PlanEntry = null,
        // Mode update
        currentModeId: ?[]const u8 = null,
        // Available commands update
        availableCommands: ?[]const SlashCommand = null,
    };

    pub const UpdateType = enum {
        agent_message_chunk,
        user_message_chunk,
        agent_thought_chunk,
        tool_call,
        tool_call_update,
        plan,
        available_commands_update,
        current_mode_update,
    };

    pub const ContentChunk = struct {
        type: []const u8 = "text",
        text: ?[]const u8 = null,
        data: ?[]const u8 = null,
        mediaType: ?[]const u8 = null,
    };

    pub const ToolKind = enum {
        read,
        write,
        edit,
        command,
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
    toolName: []const u8,
    toolInput: std.json.Value,
    interrupt: bool = false,
    options: []const PermissionOption,
};

pub const PermissionOption = struct {
    kind: PermissionKind,
    name: []const u8,
    optionId: []const u8,
};

pub const PermissionKind = enum {
    allow_once,
    allow_session,
    deny,
};

pub const PermissionResponse = struct {
    outcome: PermissionOutcome,
};

pub const PermissionOutcome = struct {
    outcome: OutcomeKind,
    optionId: ?[]const u8 = null,
};

pub const OutcomeKind = enum {
    allowed,
    denied,
    cancelled,
};

// =============================================================================
// File System (Agent → Client)
// =============================================================================

pub const ReadTextFileRequest = struct {
    path: []const u8,
};

pub const ReadTextFileResponse = struct {
    content: []const u8,
};

pub const WriteTextFileRequest = struct {
    path: []const u8,
    content: []const u8,
};

pub const WriteTextFileResponse = struct {};

// =============================================================================
// Terminal (Agent → Client)
// =============================================================================

pub const CreateTerminalRequest = struct {
    command: []const u8,
    cwd: ?[]const u8 = null,
};

pub const CreateTerminalResponse = struct {
    terminalId: []const u8,
};

pub const TerminalOutputRequest = struct {
    terminalId: []const u8,
};

pub const TerminalOutputResponse = struct {
    output: []const u8,
    exitCode: ?i32 = null,
};

pub const TerminalKillRequest = struct {
    terminalId: []const u8,
};

pub const TerminalReleaseRequest = struct {
    terminalId: []const u8,
};

// =============================================================================
// Set Mode
// =============================================================================

pub const SetModeRequest = struct {
    sessionId: []const u8,
    mode: PermissionMode,
};

pub const PermissionMode = enum {
    default,
    acceptEdits,
    bypassPermissions,
    dontAsk,
    plan,
};
