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
    user_message: UserMessage,
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

pub const UserMessage = struct {
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

// JSON-RPC types
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const ErrorCode = struct {
    pub const ParseError = -32700;
    pub const InvalidRequest = -32600;
    pub const MethodNotFound = -32601;
    pub const InvalidParams = -32602;
    pub const InternalError = -32603;
};

// Notification type (no id field)
pub const JsonRpcNotification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

fn jsonAlloc(alloc: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{ .emit_null_optional_fields = false });
}

test "StreamChunk serialization" {
    const chunk = StreamChunk{ .text = "Hello", .is_thought = false };
    const json = try jsonAlloc(testing.allocator, chunk);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"text\":\"Hello\",\"is_thought\":false}", json);
}

test "StreamChunk thought serialization" {
    const chunk = StreamChunk{ .text = "thinking...", .is_thought = true };
    const json = try jsonAlloc(testing.allocator, chunk);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"text\":\"thinking...\",\"is_thought\":true}", json);
}

test "ToolCall serialization" {
    const call = ToolCall{
        .id = "tc-123",
        .name = "Bash",
        .label = "Run command",
        .input = "{\"command\":\"ls\"}",
    };
    const json = try jsonAlloc(testing.allocator, call);
    defer testing.allocator.free(json);

    const summary = .{
        .has_id = std.mem.indexOf(u8, json, "\"id\":\"tc-123\"") != null,
        .has_name = std.mem.indexOf(u8, json, "\"name\":\"Bash\"") != null,
        .has_label = std.mem.indexOf(u8, json, "\"label\":\"Run command\"") != null,
        .has_input = std.mem.indexOf(u8, json, "\"input\":") != null,
    };
    try (ohsnap{}).snap(@src(),
        \\ws.protocol.test.ToolCall serialization__struct_<^\d+$>
        \\  .has_id: bool = true
        \\  .has_name: bool = true
        \\  .has_label: bool = true
        \\  .has_input: bool = true
    ).expectEqual(summary);
}

test "PermissionRequest serialization" {
    const req = PermissionRequest{
        .id = "perm-456",
        .tool_name = "Write",
        .tool_input = "{\"path\":\"/tmp/test\"}",
    };
    const json = try jsonAlloc(testing.allocator, req);
    defer testing.allocator.free(json);

    const summary = .{
        .has_id = std.mem.indexOf(u8, json, "\"id\":\"perm-456\"") != null,
        .has_tool_name = std.mem.indexOf(u8, json, "\"tool_name\":\"Write\"") != null,
        .has_tool_input = std.mem.indexOf(u8, json, "\"tool_input\":") != null,
    };
    try (ohsnap{}).snap(@src(),
        \\ws.protocol.test.PermissionRequest serialization__struct_<^\d+$>
        \\  .has_id: bool = true
        \\  .has_tool_name: bool = true
        \\  .has_tool_input: bool = true
    ).expectEqual(summary);
}

test "JsonRpcRequest prompt serialization" {
    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"text":"Hello","files":[],"cwd":"/tmp"}
    , .{});
    defer params.deinit();

    const id = try std.json.parseFromSlice(std.json.Value, testing.allocator, "1", .{});
    defer id.deinit();

    const req = JsonRpcRequest{
        .method = "prompt",
        .params = params.value,
        .id = id.value,
    };
    const json = try jsonAlloc(testing.allocator, req);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"prompt","params":{"text":"Hello","files":[],"cwd":"/tmp"},"id":1}
        \\
    ).diff(json, true);
}

test "JsonRpcRequest cancel serialization" {
    const id = try std.json.parseFromSlice(std.json.Value, testing.allocator, "2", .{});
    defer id.deinit();

    const req = JsonRpcRequest{
        .method = "cancel",
        .id = id.value,
    };
    const json = try jsonAlloc(testing.allocator, req);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"cancel","id":2}
        \\
    ).diff(json, true);
}

test "JsonRpcRequest set_engine serialization" {
    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"engine":"claude"}
    , .{});
    defer params.deinit();

    const id = try std.json.parseFromSlice(std.json.Value, testing.allocator, "3", .{});
    defer id.deinit();

    const req = JsonRpcRequest{
        .method = "set_engine",
        .params = params.value,
        .id = id.value,
    };
    const json = try jsonAlloc(testing.allocator, req);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"set_engine","params":{"engine":"claude"},"id":3}
        \\
    ).diff(json, true);
}

test "JsonRpcRequest set_model serialization" {
    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"model":"sonnet"}
    , .{});
    defer params.deinit();

    const id = try std.json.parseFromSlice(std.json.Value, testing.allocator, "4", .{});
    defer id.deinit();

    const req = JsonRpcRequest{
        .method = "set_model",
        .params = params.value,
        .id = id.value,
    };
    const json = try jsonAlloc(testing.allocator, req);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"set_model","params":{"model":"sonnet"},"id":4}
        \\
    ).diff(json, true);
}

test "JsonRpcNotification stream_chunk serialization" {
    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"text":"chunk","is_thought":false}
    , .{});
    defer params.deinit();

    const notif = JsonRpcNotification{
        .method = "stream_chunk",
        .params = params.value,
    };
    const json = try jsonAlloc(testing.allocator, notif);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"stream_chunk","params":{"text":"chunk","is_thought":false}}
        \\
    ).diff(json, true);
}

test "JsonRpcNotification tool_call serialization" {
    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"id":"t1","name":"Read","status":"running","input":{"path":"/tmp/a"}}
    , .{});
    defer params.deinit();

    const notif = JsonRpcNotification{
        .method = "tool_call",
        .params = params.value,
    };
    const json = try jsonAlloc(testing.allocator, notif);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"tool_call","params":{"id":"t1","name":"Read","status":"running","input":{"path":"/tmp/a"}}}
        \\
    ).diff(json, true);
}

test "JsonRpcNotification status serialization" {
    const params = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"text":"Ready"}
    , .{});
    defer params.deinit();

    const notif = JsonRpcNotification{
        .method = "status",
        .params = params.value,
    };
    const json = try jsonAlloc(testing.allocator, notif);
    defer testing.allocator.free(json);
    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"status","params":{"text":"Ready"}}
        \\
    ).diff(json, true);
}

test "StateResponse serialization" {
    const state = StateResponse{
        .engine = "claude",
        .mode = "default",
        .connected = true,
    };
    const json = try jsonAlloc(testing.allocator, state);
    defer testing.allocator.free(json);

    const summary = .{
        .has_engine = std.mem.indexOf(u8, json, "\"engine\":\"claude\"") != null,
        .has_mode = std.mem.indexOf(u8, json, "\"mode\":\"default\"") != null,
        .has_connected = std.mem.indexOf(u8, json, "\"connected\":true") != null,
    };
    try (ohsnap{}).snap(@src(),
        \\ws.protocol.test.StateResponse serialization__struct_<^\d+$>
        \\  .has_engine: bool = true
        \\  .has_mode: bool = true
        \\  .has_connected: bool = true
    ).expectEqual(summary);
}

test "JsonRpcError serialization" {
    const err = JsonRpcError{
        .code = ErrorCode.MethodNotFound,
        .message = "Method not found",
    };
    const json = try jsonAlloc(testing.allocator, err);
    defer testing.allocator.free(json);

    try testing.expectEqualStrings("{\"code\":-32601,\"message\":\"Method not found\"}", json);
}

test "ErrorCode constants" {
    const summary = .{
        .parse_error = ErrorCode.ParseError,
        .invalid_request = ErrorCode.InvalidRequest,
        .method_not_found = ErrorCode.MethodNotFound,
        .invalid_params = ErrorCode.InvalidParams,
        .internal_error = ErrorCode.InternalError,
    };
    try (ohsnap{}).snap(@src(),
        \\ws.protocol.test.ErrorCode constants__struct_<^\d+$>
        \\  .parse_error: comptime_int = -32700
        \\  .invalid_request: comptime_int = -32600
        \\  .method_not_found: comptime_int = -32601
        \\  .invalid_params: comptime_int = -32602
        \\  .internal_error: comptime_int = -32603
    ).expectEqual(summary);
}
