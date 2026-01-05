const std = @import("std");
const types = @import("../core/types.zig");
const Engine = types.Engine;

// Request from Lua to Zig
pub const Request = union(enum) {
    prompt: PromptRequest,
    cancel: void,
    nudge_toggle: void,
    selection_changed: SelectionInfo,
    file_opened: FileInfo,
    file_closed: FileInfo,
    shutdown: void,
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
    session_id: SessionIdUpdate,
    error_msg: ErrorMessage,
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
};

pub const ToolResult = struct {
    id: []const u8,
    status: []const u8, // "completed", "failed", "pending"
    content: ?[]const u8 = null,
};

pub const PermissionRequest = struct {
    id: []const u8,
    tool_name: []const u8,
    input: std.json.Value,
};

pub const SessionIdUpdate = struct {
    engine: Engine,
    session_id: []const u8,
};

pub const ErrorMessage = struct {
    message: []const u8,
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
