const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const jsonrpc = @import("../jsonrpc.zig");

// =============================================================================
// LSP Base Types
// =============================================================================

/// Position in a text document (0-indexed)
pub const Position = struct {
    line: u32,
    character: u32,
};

/// Range in a text document
pub const Range = struct {
    start: Position,
    end: Position,
};

/// Location in a text document
pub const Location = struct {
    uri: []const u8,
    range: Range,
};

/// Text document identifier
pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

/// Versioned text document identifier
pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i32,
};

/// Text document item (for didOpen)
pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i32,
    text: []const u8,
};

// =============================================================================
// Diagnostics
// =============================================================================

pub const DiagnosticSeverity = enum(u8) {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,

    pub fn jsonStringify(self: DiagnosticSeverity, jw: anytype) !void {
        try jw.write(@intFromEnum(self));
    }
};

pub const DiagnosticTag = enum(u8) {
    Unnecessary = 1,
    Deprecated = 2,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?DiagnosticSeverity = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8,
    tags: ?[]const DiagnosticTag = null,
    relatedInformation: ?[]const DiagnosticRelatedInformation = null,
};

pub const DiagnosticRelatedInformation = struct {
    location: Location,
    message: []const u8,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    version: ?i32 = null,
    diagnostics: []const Diagnostic,
};

// =============================================================================
// Code Actions
// =============================================================================

pub const CodeActionKind = struct {
    pub const QuickFix = "quickfix";
    pub const Refactor = "refactor";
    pub const Source = "source";
};

pub const CodeAction = struct {
    title: []const u8,
    kind: ?[]const u8 = null,
    diagnostics: ?[]const Diagnostic = null,
    edit: ?WorkspaceEdit = null,
    command: ?Command = null,
};

pub const Command = struct {
    title: []const u8,
    command: []const u8,
    arguments: ?[]const std.json.Value = null,
};

pub const WorkspaceEdit = struct {
    documentChanges: ?[]const TextDocumentEdit = null,
};

pub const TextDocumentEdit = struct {
    textDocument: OptionalVersionedTextDocumentIdentifier,
    edits: []const TextEdit,
};

pub const OptionalVersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: ?i32 = null, // null means "don't check version"
};

pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

// =============================================================================
// Initialize
// =============================================================================

pub const InitializeParams = struct {
    processId: ?i32 = null,
    rootUri: ?[]const u8 = null,
    rootPath: ?[]const u8 = null,
    capabilities: ClientCapabilities = .{},
    workspaceFolders: ?[]const WorkspaceFolder = null,
};

pub const ClientCapabilities = struct {
    textDocument: ?TextDocumentClientCapabilities = null,
};

pub const TextDocumentClientCapabilities = struct {
    publishDiagnostics: ?PublishDiagnosticsClientCapabilities = null,
};

pub const PublishDiagnosticsClientCapabilities = struct {
    relatedInformation: ?bool = null,
    tagSupport: ?struct { valueSet: []const DiagnosticTag } = null,
};

pub const WorkspaceFolder = struct {
    uri: []const u8,
    name: []const u8,
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities,
};

pub const ServerCapabilities = struct {
    textDocumentSync: ?TextDocumentSyncOptions = null,
    codeActionProvider: ?bool = null,
    executeCommandProvider: ?ExecuteCommandOptions = null,
    diagnosticProvider: ?DiagnosticOptions = null,
    hoverProvider: ?bool = null,
    completionProvider: ?CompletionOptions = null,
};

pub const CompletionOptions = struct {
    triggerCharacters: ?[]const []const u8 = null,
    resolveProvider: ?bool = null,
};

pub const ExecuteCommandOptions = struct {
    commands: []const []const u8,
};

pub const TextDocumentSyncOptions = struct {
    openClose: ?bool = null,
    change: ?TextDocumentSyncKind = null,
    save: ?SaveOptions = null,
};

pub const TextDocumentSyncKind = enum(u8) {
    None = 0,
    Full = 1,
    Incremental = 2,

    pub fn jsonStringify(self: TextDocumentSyncKind, jw: anytype) !void {
        try jw.write(@intFromEnum(self));
    }
};

pub const SaveOptions = struct {
    includeText: ?bool = null,
};

pub const DiagnosticOptions = struct {
    interFileDependencies: bool = false,
    workspaceDiagnostics: bool = false,
};

// =============================================================================
// Text Document Notifications
// =============================================================================

pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,
};

pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const DidChangeTextDocumentParams = struct {
    textDocument: VersionedTextDocumentIdentifier,
    contentChanges: []const TextDocumentContentChangeEvent,
};

pub const TextDocumentContentChangeEvent = struct {
    range: ?Range = null,
    text: []const u8,
};

pub const DidSaveTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
    text: ?[]const u8 = null,
};

// =============================================================================
// Code Action Request
// =============================================================================

pub const CodeActionParams = struct {
    textDocument: TextDocumentIdentifier,
    range: Range,
    context: CodeActionContext,
};

pub const CodeActionContext = struct {
    diagnostics: []const Diagnostic,
    only: ?[]const []const u8 = null,
};

// =============================================================================
// Execute Command Request
// =============================================================================

pub const ExecuteCommandParams = struct {
    command: []const u8,
    arguments: ?[]const std.json.Value = null,
};

// =============================================================================
// Hover
// =============================================================================

pub const HoverParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

// =============================================================================
// Completion
// =============================================================================

pub const CompletionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    context: ?CompletionContext = null,
};

pub const CompletionContext = struct {
    triggerKind: u8,
    triggerCharacter: ?[]const u8 = null,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u8 = null, // 1=Text, 6=Variable, 15=Snippet, etc.
    detail: ?[]const u8 = null,
    documentation: ?MarkupContent = null,
    insertText: ?[]const u8 = null,
    sortText: ?[]const u8 = null, // Controls ordering in completion list
};

pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

// =============================================================================
// LSP Transport (Content-Length framing)
// =============================================================================

pub const Transport = struct {
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    allocator: Allocator,
    read_buffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Transport {
        return .{
            .reader = reader,
            .writer = writer,
            .allocator = allocator,
            .read_buffer = .empty,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.read_buffer.deinit(self.allocator);
    }

    /// Read next LSP message (Content-Length framed)
    pub fn readMessage(self: *Transport) !?jsonrpc.ParsedRequest {
        // Read headers until empty line
        var content_length: ?usize = null;
        var line_buf: [256]u8 = undefined;

        while (true) {
            const line = self.reader.readUntilDelimiter(&line_buf, '\n') catch |e| switch (e) {
                error.EndOfStream => return null,
                else => return e,
            };

            // Strip CR if present
            const header = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;

            // Empty line = end of headers
            if (header.len == 0) break;

            // Parse Content-Length header
            if (mem.startsWith(u8, header, "Content-Length: ")) {
                content_length = std.fmt.parseInt(usize, header[16..], 10) catch return error.InvalidHeader;
            }
        }

        const length = content_length orelse return error.MissingContentLength;

        // Read exactly content_length bytes
        self.read_buffer.clearRetainingCapacity();
        try self.read_buffer.resize(self.allocator, length);

        const bytes_read = try self.reader.readAll(self.read_buffer.items);
        if (bytes_read != length) return error.UnexpectedEof;

        // Parse JSON-RPC message
        return try jsonrpc.parseRequest(self.allocator, self.read_buffer.items);
    }

    /// Write LSP message with Content-Length header
    pub fn writeMessage(self: *Transport, json: []const u8) !void {
        // Write header
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{json.len}) catch unreachable;
        try self.writer.writeAll(header);

        // Write content
        try self.writer.writeAll(json);
    }

    /// Write a JSON-RPC response
    pub fn writeResponse(self: *Transport, response: jsonrpc.Response) !void {
        const json = try jsonrpc.serializeResponse(self.allocator, response);
        defer self.allocator.free(json);
        try self.writeMessage(json);
    }

    /// Write a typed response
    pub fn writeTypedResponse(self: *Transport, id: ?jsonrpc.Request.Id, result: anytype) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("result");
        try jw.write(result);
        try jw.objectField("id");
        if (id) |i| {
            switch (i) {
                .string => |s| try jw.write(s),
                .number => |n| try jw.write(n),
                .null => try jw.write(null),
            }
        } else {
            try jw.write(null);
        }
        try jw.endObject();

        const json = try out.toOwnedSlice();
        defer self.allocator.free(json);
        try self.writeMessage(json);
    }

    /// Write a notification
    pub fn writeNotification(self: *Transport, method: []const u8, params: anytype) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write(method);
        try jw.objectField("params");
        try jw.write(params);
        try jw.endObject();

        const json = try out.toOwnedSlice();
        defer self.allocator.free(json);
        try self.writeMessage(json);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Position serializes correctly" {
    const pos = Position{ .line = 10, .character = 5 };
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(pos);
    const json = try out.toOwnedSlice();
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"line\":10,\"character\":5}", json);
}

test "Diagnostic serializes with severity" {
    const diag = Diagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 10 },
        },
        .severity = .Information,
        .source = "banjo",
        .message = "Note: test note",
    };

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(diag);
    const json = try out.toOwnedSlice();
    defer testing.allocator.free(json);

    // Verify key parts
    try testing.expect(mem.indexOf(u8, json, "\"severity\":3") != null);
    try testing.expect(mem.indexOf(u8, json, "\"source\":\"banjo\"") != null);
    try testing.expect(mem.indexOf(u8, json, "\"message\":\"Note: test note\"") != null);
}

test "ServerCapabilities serializes" {
    const caps = ServerCapabilities{
        .textDocumentSync = .{
            .openClose = true,
            .change = .Full,
        },
        .codeActionProvider = true,
    };

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(caps);
    const json = try out.toOwnedSlice();
    defer testing.allocator.free(json);

    try testing.expect(mem.indexOf(u8, json, "\"openClose\":true") != null);
    try testing.expect(mem.indexOf(u8, json, "\"change\":1") != null);
    try testing.expect(mem.indexOf(u8, json, "\"codeActionProvider\":true") != null);
}

test "Transport reads Content-Length message" {
    const json_body = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}";
    const message = "Content-Length: 46\r\n\r\n" ++ json_body;
    var fbs = std.io.fixedBufferStream(message);

    var transport = Transport.init(testing.allocator, fbs.reader().any(), undefined);
    defer transport.deinit();

    const parsed = try transport.readMessage();
    try testing.expect(parsed != null);
    var p = parsed.?;
    defer p.deinit();

    try testing.expectEqualStrings("initialize", p.request.method);
    try testing.expectEqual(@as(i64, 1), p.request.id.?.number);
}

test "Transport handles missing Content-Length" {
    const message = "Content-Type: application/json\r\n\r\n{}";
    var fbs = std.io.fixedBufferStream(message);

    var transport = Transport.init(testing.allocator, fbs.reader().any(), undefined);
    defer transport.deinit();

    const result = transport.readMessage();
    try testing.expectError(error.MissingContentLength, result);
}

// Snapshot tests
const ohsnap = @import("ohsnap");

test "snapshot: PublishDiagnosticsParams" {
    const params = PublishDiagnosticsParams{
        .uri = "file:///test.zig",
        .diagnostics = &.{
            .{
                .range = .{
                    .start = .{ .line = 5, .character = 0 },
                    .end = .{ .line = 5, .character = 20 },
                },
                .severity = .Information,
                .source = "banjo",
                .message = "Note: important comment",
            },
        },
    };

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(params);
    const json = try out.toOwnedSlice();
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(
        @src(),
        \\{"uri":"file:///test.zig","diagnostics":[{"range":{"start":{"line":5,"character":0},"end":{"line":5,"character":20}},"severity":3,"source":"banjo","message":"Note: important comment"}]}
    ,
    ).diff(json, true);
}

test "snapshot: InitializeResult" {
    const result = InitializeResult{
        .capabilities = .{
            .textDocumentSync = .{
                .openClose = true,
                .change = .Full,
            },
            .codeActionProvider = true,
        },
    };

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(result);
    const json = try out.toOwnedSlice();
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(
        @src(),
        \\{"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"codeActionProvider":true}}
    ,
    ).diff(json, true);
}
