const std = @import("std");

pub const PROTOCOL_VERSION = "2024-11-05";
pub const SERVER_NAME = "banjo-neovim";
pub const SERVER_VERSION = "0.1.0";

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

// Standard JSON-RPC error codes
pub const ErrorCode = struct {
    pub const ParseError = -32700;
    pub const InvalidRequest = -32600;
    pub const MethodNotFound = -32601;
    pub const InvalidParams = -32602;
    pub const InternalError = -32603;
};

// MCP Initialize types

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: ClientInfo,
};

pub const ClientCapabilities = struct {
    // Empty for now - client capabilities we care about
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8 = PROTOCOL_VERSION,
    capabilities: ServerCapabilities = .{},
    serverInfo: ServerInfo = .{},
};

pub const ServerCapabilities = struct {
    logging: EmptyObject = .{},
    prompts: EmptyObject = .{},
    resources: EmptyObject = .{},
    tools: EmptyObject = .{},
};

pub const ServerInfo = struct {
    name: []const u8 = SERVER_NAME,
    version: []const u8 = SERVER_VERSION,
};

pub const EmptyObject = struct {};

// Tool types

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: InputSchema,
};

pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: ?std.json.Value = null,
    required: ?[]const []const u8 = null,
};

pub const ToolsListResult = struct {
    tools: []const ToolDefinition,
};

pub const ToolsCallParams = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

pub const ToolCallResult = struct {
    content: []const ContentItem,
};

pub const ContentItem = struct {
    type: []const u8 = "text",
    text: []const u8,
};

// Tool input types

pub const OpenFileInput = struct {
    filePath: []const u8,
    preview: bool = false,
    startLine: ?u32 = null,
    endLine: ?u32 = null,
    makeFrontmost: bool = true,
};

pub const OpenDiffInput = struct {
    old_file_path: []const u8,
    new_file_path: []const u8,
    new_file_contents: []const u8,
    tab_name: ?[]const u8 = null,
};

pub const GetDiagnosticsInput = struct {
    uri: ?[]const u8 = null,
};

pub const CheckDocumentDirtyInput = struct {
    filePath: []const u8,
};

pub const SaveDocumentInput = struct {
    filePath: []const u8,
};

pub const CloseTabInput = struct {
    filePath: []const u8,
};

// Tool output types

pub const SelectionResult = struct {
    text: []const u8 = "",
    file: []const u8 = "",
    range: ?SelectionRange = null,
};

pub const SelectionRange = struct {
    startLine: u32,
    startCol: u32,
    endLine: u32,
    endCol: u32,
};

pub const EditorInfo = struct {
    filePath: []const u8,
    isActive: bool,
    isDirty: bool,
};

pub const OpenEditorsResult = struct {
    editors: []const EditorInfo,
};

pub const WorkspaceFoldersResult = struct {
    folders: []const []const u8,
};

pub const DiagnosticInfo = struct {
    message: []const u8,
    severity: i32,
    range: DiagnosticRange,
};

pub const DiagnosticRange = struct {
    start: Position,
    end: Position,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const DiagnosticsResult = struct {
    diagnostics: []const DiagnosticInfo,
};

pub const DirtyCheckResult = struct {
    isDirty: bool,
};

pub const SuccessResult = struct {
    success: bool,
};

// Tool definitions

pub fn getToolDefinitions() []const ToolDefinition {
    return &tool_definitions;
}

const tool_definitions = [_]ToolDefinition{
    .{
        .name = "openFile",
        .description = "Open a file in the editor with optional line range selection",
        .inputSchema = .{
            .required = &[_][]const u8{"filePath"},
        },
    },
    .{
        .name = "openDiff",
        .description = "Show a diff view comparing original file to new contents (blocking until user accepts/rejects)",
        .inputSchema = .{
            .required = &[_][]const u8{ "old_file_path", "new_file_path", "new_file_contents" },
        },
    },
    .{
        .name = "getCurrentSelection",
        .description = "Get the currently selected text in the active editor",
        .inputSchema = .{},
    },
    .{
        .name = "getLatestSelection",
        .description = "Get the most recently captured selection (may be from visual mode)",
        .inputSchema = .{},
    },
    .{
        .name = "getOpenEditors",
        .description = "List all currently open editor buffers",
        .inputSchema = .{},
    },
    .{
        .name = "getWorkspaceFolders",
        .description = "Get the workspace folder paths",
        .inputSchema = .{},
    },
    .{
        .name = "getDiagnostics",
        .description = "Get LSP diagnostics for a file or all open files",
        .inputSchema = .{},
    },
    .{
        .name = "checkDocumentDirty",
        .description = "Check if a document has unsaved changes",
        .inputSchema = .{
            .required = &[_][]const u8{"filePath"},
        },
    },
    .{
        .name = "saveDocument",
        .description = "Save a document to disk",
        .inputSchema = .{
            .required = &[_][]const u8{"filePath"},
        },
    },
    .{
        .name = "closeTab",
        .description = "Close an editor tab/buffer",
        .inputSchema = .{
            .required = &[_][]const u8{"filePath"},
        },
    },
    .{
        .name = "closeAllDiffTabs",
        .description = "Close all open diff view tabs",
        .inputSchema = .{},
    },
    .{
        .name = "executeCode",
        .description = "Execute code in a Jupyter kernel (not supported in Neovim)",
        .inputSchema = .{},
    },
};

// MCP method names
pub const Method = struct {
    pub const Initialize = "initialize";
    pub const Initialized = "notifications/initialized";
    pub const ToolsList = "tools/list";
    pub const ToolsCall = "tools/call";
};

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "InitializeResult serialization" {
    const result = InitializeResult{};

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(result);
    const buf = try out.toOwnedSlice();
    defer testing.allocator.free(buf);

    const parsed = try std.json.parseFromSlice(InitializeResult, testing.allocator, buf, .{});
    defer parsed.deinit();
    const summary = .{
        .protocol_version = parsed.value.protocolVersion,
        .server_name = parsed.value.serverInfo.name,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.mcp_types.test.InitializeResult serialization__struct_<^\d+$>
        \\  .protocol_version: []const u8
        \\    "2024-11-05"
        \\  .server_name: []const u8
        \\    "banjo-neovim"
    ).expectEqual(summary);
}

test "ToolCallResult serialization" {
    const result = ToolCallResult{
        .content = &[_]ContentItem{
            .{ .text = "{\"success\":true}" },
        },
    };

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(result);
    const buf = try out.toOwnedSlice();
    defer testing.allocator.free(buf);

    try (ohsnap{}).snap(@src(),
        \\{"content":[{"type":"text","text":"{\"success\":true}"}]}
    ).diff(buf, true);
}

test "getToolDefinitions count" {
    const tools = getToolDefinitions();
    const summary = .{ .count = tools.len };
    try (ohsnap{}).snap(@src(),
        \\nvim.mcp_types.test.getToolDefinitions count__struct_<^\d+$>
        \\  .count: usize = 12
    ).expectEqual(summary);
}
