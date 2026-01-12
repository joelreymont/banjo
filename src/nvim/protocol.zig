const std = @import("std");
const types = @import("../core/types.zig");
const permission_mode = @import("../core/permission_mode.zig");
const Engine = types.Engine;
const ModelInfo = types.ModelInfo;

// Permission modes for Claude Code
pub const PermissionMode = permission_mode.PermissionMode;

// Request from Lua to Zig
pub const Request = union(enum) {
    prompt: PromptRequest,
    cancel: void,
    nudge_toggle: void,
    set_engine: SetEngineRequest,
    set_model: SetModelRequest,
    set_permission_mode: SetPermissionModeRequest,
    get_state: void,
    selection_changed: SelectionInfo,
    file_opened: FileInfo,
    file_closed: FileInfo,
    shutdown: void,
};

pub const SetEngineRequest = struct {
    engine: []const u8, // "claude", "codex"
};

pub const SetModelRequest = struct {
    model: []const u8, // "sonnet", "opus", "haiku"
};

pub const SetPermissionModeRequest = struct {
    mode: []const u8, // "default", "accept_edits", "auto_approve", "plan_only"
};

pub const ApprovalResponseRequest = struct {
    id: []const u8,
    decision: []const u8, // "approve" or "decline"
};

pub const PermissionResponseRequest = struct {
    id: []const u8,
    decision: []const u8, // "allow", "allow_always", "deny"
};

pub const PromptRequest = struct {
    text: []const u8,
    files: []const FileRef = &.{},
    cwd: ?[]const u8 = null,
};

pub const FileRef = struct {
    path: []const u8,
    content: ?[]const u8 = null,
    selection: ?SelectionRange = null,
};

pub const SelectionRange = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

pub const SelectionInfo = struct {
    file: []const u8,
    range: ?SelectionRange = null,
    content: ?[]const u8 = null,
};

pub const FileInfo = struct {
    path: []const u8,
};

// Notification from Zig to Lua
pub const Notification = union(enum) {
    ready: void,
    stream_start: StreamStart,
    stream_chunk: StreamChunk,
    stream_end: void,
    status: StatusUpdate,
    tool_call: ToolCall,
    tool_result: ToolResult,
    permission_request: PermissionRequest,
    approval_request: ApprovalRequest,
    session_id: SessionIdUpdate,
    state: StateResponse,
    error_msg: ErrorMessage,
};

pub const StateResponse = struct {
    engine: []const u8,
    model: ?[]const u8 = null,
    mode: []const u8,
    session_id: ?[]const u8 = null,
    connected: bool,
    models: []const ModelInfo = &.{},
    version: []const u8 = "",
};

pub const ApprovalRequest = struct {
    id: []const u8,
    tool_name: []const u8,
    arguments: ?[]const u8 = null,
    risk_level: []const u8 = "medium", // "low", "medium", "high"
};

pub const StreamStart = struct {
    engine: Engine,
};

pub const StreamChunk = struct {
    text: []const u8,
    is_thought: bool = false,
};

pub const StatusUpdate = struct {
    text: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    label: []const u8,
    input: ?[]const u8 = null,
};

pub const ToolResult = struct {
    id: []const u8,
    status: []const u8, // "completed", "failed", "pending"
    content: ?[]const u8 = null,
};

pub const PermissionRequest = struct {
    id: []const u8,
    tool_name: []const u8,
    tool_input: ?[]const u8 = null, // JSON string preview of tool input
};

pub const SessionIdUpdate = struct {
    engine: Engine,
    session_id: []const u8,
};

pub const SessionEvent = struct {};

pub const ErrorMessage = struct {
    message: []const u8,
};

pub const DebugInfo = struct {
    claude_bridge_alive: bool,
    codex_bridge_alive: bool,
    prompt_count: u32,
};

// JSON-RPC types (re-exported from mcp_types)
const mcp_types = @import("mcp_types.zig");
pub const JsonRpcRequest = mcp_types.JsonRpcRequest;
pub const JsonRpcResponse = mcp_types.JsonRpcResponse;
pub const JsonRpcError = mcp_types.JsonRpcError;

// Notification type (no id field, not in mcp_types)
pub const JsonRpcNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};
