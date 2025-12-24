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
    resume_: ?struct {} = null,
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

pub const SessionUpdate = struct {
    sessionId: []const u8,
    update: Update,

    pub const Update = struct {
        kind: UpdateKind,
        content: ?[]const u8 = null,
        title: ?[]const u8 = null,
        toolCallId: ?[]const u8 = null,
        toolKind: ?ToolKind = null,
        entries: ?[]const PlanEntry = null,
    };

    pub const UpdateKind = enum {
        text,
        tool_call,
        tool_call_update,
        plan,
        thinking,
    };

    pub const ToolKind = enum {
        read,
        write,
        edit,
        execute,
        think,
        search,
        fetch,
    };

    pub const PlanEntry = struct {
        content: []const u8,
        status: PlanStatus,
        priority: []const u8 = "medium",
    };

    pub const PlanStatus = enum {
        pending,
        in_progress,
        completed,
    };
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
