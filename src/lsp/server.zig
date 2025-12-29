const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const protocol = @import("protocol.zig");
const diagnostics = @import("diagnostics.zig");
const comments = @import("../notes/comments.zig");
const jsonrpc = @import("../jsonrpc.zig");
const summary = @import("summary.zig");

const log = std.log.scoped(.lsp);

/// Debounce delay for diagnostics (150ms)
const DEBOUNCE_NS: i128 = 150 * std.time.ns_per_ms;

/// LSP Server state
pub const Server = struct {
    allocator: Allocator,
    transport: protocol.Transport,
    root_uri: ?[]const u8,
    initialized: bool,

    /// Open documents: uri -> content
    documents: std.StringHashMap([]const u8),

    /// Pending diagnostic publishes: uri -> last_change_timestamp
    pending_diagnostics: std.StringHashMap(i128),

    /// Note index for backlink lookups (rebuilt on each file change)
    note_index: diagnostics.NoteIndex,

    pub fn init(allocator: Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Server {
        return .{
            .allocator = allocator,
            .transport = protocol.Transport.init(allocator, reader, writer),
            .root_uri = null,
            .initialized = false,
            .documents = std.StringHashMap([]const u8).init(allocator),
            .pending_diagnostics = std.StringHashMap(i128).init(allocator),
            .note_index = diagnostics.NoteIndex.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.transport.deinit();
        if (self.root_uri) |uri| {
            self.allocator.free(uri);
        }
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
        self.pending_diagnostics.deinit();
        self.note_index.deinit();
    }

    /// Main server loop
    pub fn run(self: *Server) !void {
        while (true) {
            // Flush any pending diagnostics that have exceeded debounce delay
            self.flushPendingDiagnostics() catch |e| {
                log.err("Failed to flush diagnostics: {}", .{e});
            };

            const parsed = self.transport.readMessage() catch |e| {
                log.err("Failed to read message: {}", .{e});
                continue;
            };

            if (parsed) |*p| {
                defer {
                    var mp = p.*;
                    mp.deinit();
                }
                self.handleRequest(p.request) catch |e| {
                    log.err("Failed to handle request: {}", .{e});
                };
            } else {
                // EOF
                break;
            }
        }
    }

    /// Flush pending diagnostics that have exceeded debounce delay
    fn flushPendingDiagnostics(self: *Server) !void {
        if (self.pending_diagnostics.count() == 0) return;

        const now = std.time.nanoTimestamp();

        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.pending_diagnostics.iterator();
        while (it.next()) |entry| {
            const elapsed = now - entry.value_ptr.*;
            // Flush if debounce exceeded OR if clock went backwards (NTP, suspend, etc.)
            if (elapsed >= DEBOUNCE_NS or elapsed < 0) {
                if (elapsed < 0) {
                    log.warn("Diagnostics clock skew detected (elapsed {d}ns)", .{elapsed});
                }
                const uri = entry.key_ptr.*;
                if (self.documents.get(uri)) |content| {
                    try self.publishDiagnostics(uri, content);
                }
                try to_remove.append(self.allocator, uri);
            }
        }

        // Remove flushed entries
        for (to_remove.items) |uri| {
            _ = self.pending_diagnostics.remove(uri);
        }
    }

    const Handler = *const fn (*Server, jsonrpc.Request) anyerror!void;

    const method_handlers = std.StaticStringMap(Handler).initComptime(.{
        .{ "initialize", handleInitialize },
        .{ "initialized", handleInitialized },
        .{ "shutdown", handleShutdown },
        .{ "exit", handleExit },
        .{ "textDocument/didOpen", handleDidOpen },
        .{ "textDocument/didChange", handleDidChange },
        .{ "textDocument/didClose", handleDidClose },
        .{ "textDocument/didSave", handleDidSave },
        .{ "textDocument/codeAction", handleCodeAction },
        .{ "textDocument/hover", handleHover },
        .{ "textDocument/completion", handleCompletion },
        .{ "textDocument/semanticTokens/full", handleSemanticTokens },
        .{ "textDocument/definition", handleDefinition },
        .{ "workspace/executeCommand", handleExecuteCommand },
    });

    fn handleRequest(self: *Server, request: jsonrpc.Request) !void {
        if (method_handlers.get(request.method)) |handler| {
            try handler(self, request);
        } else if (request.id) |id| {
            try self.transport.writeResponse(jsonrpc.Response.err(
                id,
                jsonrpc.Error.MethodNotFound,
                "Method not found",
            ));
        }
    }

    fn handleInitialized(self: *Server, request: jsonrpc.Request) !void {
        _ = request;
        self.initialized = true;
    }

    fn handleExit(self: *Server, request: jsonrpc.Request) !void {
        _ = self;
        _ = request;
    }

    fn handleInitialize(self: *Server, request: jsonrpc.Request) !void {
        // Parse params
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.InitializeParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeResponse(jsonrpc.Response.err(
                    request.id,
                    jsonrpc.Error.InvalidParams,
                    "Invalid initialize params",
                ));
                return;
            };
            break :blk parsed;
        } else null;
        defer if (params) |p| p.deinit();

        // Store root URI
        if (params) |p| {
            if (p.value.rootUri) |uri| {
                if (self.root_uri) |old| {
                    self.allocator.free(old);
                }
                self.root_uri = try self.allocator.dupe(u8, uri);
            }
        }

        // Send capabilities
        const result = protocol.InitializeResult{
            .capabilities = .{
                .textDocumentSync = .{
                    .openClose = true,
                    .change = .Full,
                    .save = .{ .includeText = true },
                },
                .codeActionProvider = true,
                .hoverProvider = true,
                .definitionProvider = true,
                .completionProvider = .{
                    .triggerCharacters = &[_][]const u8{"["},
                },
                .executeCommandProvider = .{
                    .commands = &[_][]const u8{
                        "banjo.createNote",
                        "banjo.showBacklinks",
                    },
                },
                .semanticTokensProvider = .{
                    .legend = .{
                        .tokenTypes = &[_][]const u8{ "macro", "string" },
                        .tokenModifiers = &[_][]const u8{},
                    },
                    .full = true,
                },
            },
        };

        try self.transport.writeTypedResponse(request.id, result);
    }

    fn handleShutdown(self: *Server, request: jsonrpc.Request) !void {
        try self.transport.writeTypedResponse(request.id, null);
    }

    fn handleDidOpen(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.DidOpenTextDocumentParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch |err| {
                log.warn("DidOpen parse failed: {}", .{err});
                return;
            };
            break :blk parsed;
        } else return;
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const text = params.value.textDocument.text;

        // Store document content
        const uri_copy = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_copy);
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);

        const put_result = try self.documents.getOrPut(uri_copy);
        if (put_result.found_existing) {
            self.allocator.free(uri_copy);
            _ = self.pending_diagnostics.remove(put_result.key_ptr.*);
            self.allocator.free(put_result.value_ptr.*);
        }
        put_result.value_ptr.* = text_copy;

        // Rebuild index and publish diagnostics
        try self.rebuildIndex();
        try self.publishDiagnostics(uri, text);
    }

    fn handleDidChange(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.DidChangeTextDocumentParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch |err| {
                log.warn("DidChange parse failed: {}", .{err});
                return;
            };
            break :blk parsed;
        } else return;
        defer params.deinit();

        const uri = params.value.textDocument.uri;

        // Full sync: last change is the full content
        if (params.value.contentChanges.len > 0) {
            const new_text = params.value.contentChanges[params.value.contentChanges.len - 1].text;

            if (self.documents.fetchRemove(uri)) |old| {
                _ = self.pending_diagnostics.remove(uri);
                self.allocator.free(old.key);
                self.allocator.free(old.value);
            }

            const uri_copy = try self.allocator.dupe(u8, uri);
            errdefer self.allocator.free(uri_copy);
            const text_copy = try self.allocator.dupe(u8, new_text);
            errdefer self.allocator.free(text_copy);

            try self.documents.put(uri_copy, text_copy);

            // Schedule diagnostics with debouncing
            try self.scheduleDiagnostics(uri_copy);
        }
    }

    fn scheduleDiagnostics(self: *Server, uri: []const u8) !void {
        const now = std.time.nanoTimestamp();
        try self.pending_diagnostics.put(uri, now);
    }

    fn handleDidClose(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.DidCloseTextDocumentParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch return;
            break :blk parsed;
        } else return;
        defer params.deinit();

        const uri = params.value.textDocument.uri;

        _ = self.pending_diagnostics.remove(uri);

        if (self.documents.fetchRemove(uri)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        // Clear diagnostics
        try self.transport.writeNotification("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = &.{},
        });

        // Rebuild index without this file
        try self.rebuildIndex();
    }

    fn handleDidSave(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.DidSaveTextDocumentParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch return;
            break :blk parsed;
        } else return;
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const content = params.value.text orelse self.documents.get(uri);

        if (content) |text| {
            try self.rebuildIndex();
            try self.publishDiagnostics(uri, text);
        }
    }

    fn handleHover(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.HoverParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeTypedResponse(request.id, null);
                return;
            };
            break :blk parsed;
        } else {
            try self.transport.writeTypedResponse(request.id, null);
            return;
        };
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const line = params.value.position.line + 1; // Convert to 1-indexed

        const content = self.documents.get(uri) orelse {
            try self.transport.writeTypedResponse(request.id, null);
            return;
        };

        // Find note on this line
        const note = self.findNoteAtLine(content, line) orelse {
            try self.transport.writeTypedResponse(request.id, null);
            return;
        };
        defer {
            self.allocator.free(note.id);
            self.allocator.free(note.content);
            for (note.links) |link| self.allocator.free(link);
            self.allocator.free(note.links);
        }

        // Build hover content with backlinks
        var hover_content: std.io.Writer.Allocating = .init(self.allocator);
        defer hover_content.deinit();

        try hover_content.writer.print("**Note:** {s}\n\n", .{note.content});
        try hover_content.writer.print("ID: `{s}`\n", .{note.id});

        // Add backlinks with context if any
        if (self.note_index.getBacklinks(note.id)) |backlink_ids| {
            try hover_content.writer.writeAll("\n---\n**Backlinks:**\n");
            for (backlink_ids) |bl_id| {
                if (self.note_index.getNote(bl_id)) |bl_note| {
                    const filename = std.fs.path.basename(bl_note.file_path);
                    try hover_content.writer.print("\n**{s}** (line {d}):\n", .{ filename, bl_note.line });
                    const bl_summary = summary.getSummary(bl_note.content, .{ .max_len = 40, .prefer_word_boundary = true });
                    try hover_content.writer.print("> {s}\n", .{bl_summary});

                    // Show context from file if available
                    const bl_uri = pathToUri(self.allocator, bl_note.file_path) catch null;
                    if (bl_uri) |uri_str| {
                        defer self.allocator.free(uri_str);
                        if (self.documents.get(uri_str)) |doc_content| {
                            const context = getLineContext(doc_content, bl_note.line, 1);
                            if (context.before.len > 0 or context.after.len > 0) {
                                try hover_content.writer.writeAll("```\n");
                                if (context.before.len > 0) {
                                    try hover_content.writer.print("{s}\n", .{context.before});
                                }
                                try hover_content.writer.print("→ {s}\n", .{context.current});
                                if (context.after.len > 0) {
                                    try hover_content.writer.print("{s}\n", .{context.after});
                                }
                                try hover_content.writer.writeAll("```\n");
                            }
                        }
                    }
                }
            }
        }

        const hover_text = try hover_content.toOwnedSlice();
        defer self.allocator.free(hover_text);

        const hover = protocol.Hover{
            .contents = .{
                .kind = "markdown",
                .value = hover_text,
            },
        };

        try self.transport.writeTypedResponse(request.id, hover);
    }

    fn handleDefinition(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.TextDocumentPositionParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeTypedResponse(request.id, @as(?protocol.Location, null));
                return;
            };
            break :blk parsed;
        } else {
            try self.transport.writeTypedResponse(request.id, @as(?protocol.Location, null));
            return;
        };
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const line = params.value.position.line;
        const char = params.value.position.character;

        const content = self.documents.get(uri) orelse {
            try self.transport.writeTypedResponse(request.id, @as(?protocol.Location, null));
            return;
        };

        const line_content = getLineContent(content, line) orelse {
            try self.transport.writeTypedResponse(request.id, @as(?protocol.Location, null));
            return;
        };

        // Check if cursor is on a note ID pattern: @banjo[id] or @[text](id)
        const target_id = findNoteIdAtPosition(line_content, char) orelse {
            try self.transport.writeTypedResponse(request.id, @as(?protocol.Location, null));
            return;
        };

        // Look up the target note
        if (self.note_index.getNote(target_id)) |note| {
            const target_line: u32 = if (note.line > 0) note.line - 1 else 0;
            const target_uri = try pathToUri(self.allocator, note.file_path);
            defer self.allocator.free(target_uri);
            const location = protocol.Location{
                .uri = target_uri,
                .range = .{
                    .start = .{ .line = target_line, .character = 0 },
                    .end = .{ .line = target_line, .character = 0 },
                },
            };
            try self.transport.writeTypedResponse(request.id, location);
        } else {
            try self.transport.writeTypedResponse(request.id, @as(?protocol.Location, null));
        }
    }

    fn handleCompletion(self: *Server, request: jsonrpc.Request) !void {
        log.info("handleCompletion called", .{});
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.CompletionParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeTypedResponse(request.id, protocol.CompletionList{ .items = &.{} });
                return;
            };
            break :blk parsed;
        } else {
            try self.transport.writeTypedResponse(request.id, protocol.CompletionList{ .items = &.{} });
            return;
        };
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const line = params.value.position.line;
        const char = params.value.position.character;

        const content = self.documents.get(uri) orelse {
            try self.transport.writeTypedResponse(request.id, protocol.CompletionList{ .items = &.{} });
            return;
        };

        // Check if we're after [[
        const line_content = getLineContent(content, line) orelse {
            try self.transport.writeTypedResponse(request.id, protocol.CompletionList{ .items = &.{} });
            return;
        };

        // Trigger on @[ for note links
        const line_len_u32 = std.math.cast(u32, line_content.len) orelse {
            try self.transport.writeTypedResponse(request.id, protocol.CompletionList{ .items = &.{} });
            return;
        };
        const prefix = if (char >= 2 and char <= line_len_u32) blk: {
            const char_idx: usize = @as(usize, @intCast(char));
            break :blk line_content[char_idx - 2 .. char_idx];
        } else "";
        log.info("completion check: char={d}, prefix='{s}'", .{ char, prefix });
        if (!mem.eql(u8, prefix, comments.link_prefix)) {
            try self.transport.writeTypedResponse(request.id, protocol.CompletionList{ .items = &.{} });
            return;
        }
        log.info("@[ matched, building completions", .{});

        // Build completion items - current file first, then other files
        var items: std.ArrayListUnmanaged(protocol.CompletionItem) = .empty;
        defer items.deinit(self.allocator);

        // Track allocated strings for cleanup
        var allocated_strings: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (allocated_strings.items) |s| self.allocator.free(s);
            allocated_strings.deinit(self.allocator);
        }

        // Get current file path from URI
        const current_path = uriToPath(uri) orelse uri;

        const NoteEntry = struct {
            id: []const u8,
            info: diagnostics.NoteIndex.NoteInfo,
        };

        var current_notes: std.ArrayListUnmanaged(NoteEntry) = .empty;
        var other_notes: std.ArrayListUnmanaged(NoteEntry) = .empty;
        defer current_notes.deinit(self.allocator);
        defer other_notes.deinit(self.allocator);

        var it = self.note_index.notes.iterator();
        while (it.next()) |entry| {
            const note_view = NoteEntry{
                .id = entry.key_ptr.*,
                .info = entry.value_ptr.*,
            };
            if (mem.eql(u8, note_view.info.file_path, current_path)) {
                try current_notes.append(self.allocator, note_view);
            } else {
                try other_notes.append(self.allocator, note_view);
            }
        }

        for (current_notes.items) |note_view| {
            const detail = try std.fmt.allocPrint(self.allocator, "line {d}", .{note_view.info.line});
            try allocated_strings.append(self.allocator, detail);
            try appendNoteCompletion(
                self.allocator,
                &items,
                &allocated_strings,
                note_view.id,
                note_view.info,
                detail,
                "0",
            );
        }

        for (other_notes.items) |note_view| {
            const filename = std.fs.path.basename(note_view.info.file_path);
            const detail = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ filename, note_view.info.line });
            try allocated_strings.append(self.allocator, detail);
            try appendNoteCompletion(
                self.allocator,
                &items,
                &allocated_strings,
                note_view.id,
                note_view.info,
                detail,
                "1",
            );
        }

        try self.transport.writeTypedResponse(request.id, protocol.CompletionList{
            .items = items.items,
        });
    }

    fn handleSemanticTokens(self: *Server, request: jsonrpc.Request) !void {
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                struct { textDocument: protocol.TextDocumentIdentifier },
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeTypedResponse(request.id, protocol.SemanticTokens{ .data = &.{} });
                return;
            };
            break :blk parsed;
        } else {
            try self.transport.writeTypedResponse(request.id, protocol.SemanticTokens{ .data = &.{} });
            return;
        };
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const content = self.documents.get(uri) orelse {
            try self.transport.writeTypedResponse(request.id, protocol.SemanticTokens{ .data = &.{} });
            return;
        };

        // Token data: [deltaLine, deltaStart, length, tokenType, tokenModifiers]
        var tokens: std.ArrayListUnmanaged(u32) = .empty;
        defer tokens.deinit(self.allocator);

        var prev_line: u32 = 0;
        var prev_char: u32 = 0;

        // Scan all lines for @banjo[id] and @[text](id) patterns
        var line_num: u32 = 0;
        var line_start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n' or i == content.len - 1) {
                const line_end = if (c == '\n') i else i + 1;
                const line_content = content[line_start..line_end];

                // Find @banjo[id] pattern
                if (mem.indexOf(u8, line_content, "@banjo[")) |marker_start| {
                    if (mem.indexOfPos(u8, line_content, marker_start + 7, "]")) |id_end| {
                        const delta_line = line_num - prev_line;
                        const start_char = castU32(marker_start) orelse {
                            prev_line = line_num;
                            continue;
                        };
                        const delta_char = if (delta_line == 0) start_char - prev_char else start_char;
                        const length = castU32(id_end + 1 - marker_start) orelse continue;

                        try tokens.appendSlice(self.allocator, &[_]u32{
                            delta_line, delta_char, length, 0, 0,
                        });

                        prev_line = line_num;
                        prev_char = start_char;
                    }
                }

                // Find all @[text](id) patterns
                var search_pos: usize = 0;
                while (search_pos < line_content.len) {
                    const link_start = mem.indexOfPos(u8, line_content, search_pos, comments.link_prefix) orelse break;
                    const mid = mem.indexOfPos(u8, line_content, link_start + 2, "](") orelse {
                        search_pos = link_start + 2;
                        continue;
                    };
                    const link_end = mem.indexOfPos(u8, line_content, mid + 2, ")") orelse {
                        search_pos = mid + 2;
                        continue;
                    };

                    const delta_line = line_num - prev_line;
                    const start_char = castU32(link_start) orelse {
                        prev_line = line_num;
                        search_pos = link_end + 1;
                        continue;
                    };
                    const delta_char = if (delta_line == 0) start_char - prev_char else start_char;
                    const length = castU32(link_end + 1 - link_start) orelse {
                        search_pos = link_end + 1;
                        continue;
                    };

                    try tokens.appendSlice(self.allocator, &[_]u32{
                        delta_line, delta_char, length, 1, 0,
                    });

                    prev_line = line_num;
                    prev_char = start_char;
                    search_pos = link_end + 1;
                }

                line_num += 1;
                line_start = i + 1;
            }
        }

        try self.transport.writeTypedResponse(request.id, protocol.SemanticTokens{
            .data = tokens.items,
        });
    }

    fn handleCodeAction(self: *Server, request: jsonrpc.Request) !void {
        log.info("handleCodeAction called", .{});
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.CodeActionParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeResponse(jsonrpc.Response.err(
                    request.id,
                    jsonrpc.Error.InvalidParams,
                    "Invalid code action params",
                ));
                return;
            };
            break :blk parsed;
        } else {
            try self.transport.writeTypedResponse(request.id, &[_]protocol.CodeAction{});
            return;
        };
        defer params.deinit();

        const uri = params.value.textDocument.uri;
        const line = params.value.range.start.line; // 0-indexed for edits
        const char = params.value.range.start.character;
        const file_path = uriToPath(uri) orelse {
            try self.transport.writeTypedResponse(request.id, &[_]protocol.CodeAction{});
            return;
        };

        const content = self.documents.get(uri) orelse {
            try self.transport.writeTypedResponse(request.id, &[_]protocol.CodeAction{});
            return;
        };

        var actions: std.ArrayListUnmanaged(protocol.CodeAction) = .empty;
        defer actions.deinit(self.allocator);

        // Track allocations for cleanup after response
        var allocs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (allocs.items) |s| self.allocator.free(s);
            allocs.deinit(self.allocator);
        }
        var edit_allocs: std.ArrayListUnmanaged([]protocol.TextDocumentEdit) = .empty;
        defer {
            for (edit_allocs.items) |slice| {
                for (slice) |edit| self.allocator.free(edit.edits);
                self.allocator.free(slice);
            }
            edit_allocs.deinit(self.allocator);
        }

        const line_text = getLineContent(content, line) orelse "";
        const is_comment = isCommentLine(content, line + 1); // isCommentLine uses 1-indexed

        // Check if line has a banjo note (skip if so - no create action needed)
        if (self.findNoteAtLine(content, line + 1)) |note| {
            self.allocator.free(note.id);
            self.allocator.free(note.content);
            for (note.links) |link| self.allocator.free(link);
            self.allocator.free(note.links);
            // Could add "Delete Note" action here in the future
        } else if (is_comment) {
            // Comment line: insert @banjo[id] at cursor position
            const note_id = comments.generateNoteId();
            const insert_text = try std.fmt.allocPrint(self.allocator, "@banjo[{s}] ", .{&note_id});
            try allocs.append(self.allocator, insert_text);

            const title = if (hasTodoPattern(line_text)) |pattern|
                try std.fmt.allocPrint(self.allocator, "Convert {s} to Banjo Note", .{pattern})
            else
                try self.allocator.dupe(u8, "Create Banjo Note");
            try allocs.append(self.allocator, title);

            const edits = try self.allocator.dupe(protocol.TextEdit, &[_]protocol.TextEdit{.{
                .range = .{
                    .start = .{ .line = line, .character = char },
                    .end = .{ .line = line, .character = char },
                },
                .newText = insert_text,
            }});
            const doc_changes = try self.allocator.dupe(protocol.TextDocumentEdit, &[_]protocol.TextDocumentEdit{.{
                .textDocument = .{ .uri = uri },
                .edits = edits,
            }});
            try edit_allocs.append(self.allocator, doc_changes);

            try actions.append(self.allocator, .{
                .title = title,
                .kind = protocol.CodeActionKind.QuickFix,
                .edit = .{ .documentChanges = doc_changes },
            });
        } else if (mem.trim(u8, line_text, " \t").len > 0) {
            // Code line: insert note comment above
            const prefix = comments.getCommentPrefix(file_path);
            const note_id = comments.generateNoteId();
            const indent = getIndent(line_text);

            const new_line = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s} @banjo[{s}] NOTE:\n",
                .{ indent, prefix, &note_id },
            );
            try allocs.append(self.allocator, new_line);

            const edits = try self.allocator.dupe(protocol.TextEdit, &[_]protocol.TextEdit{.{
                .range = .{
                    .start = .{ .line = line, .character = 0 },
                    .end = .{ .line = line, .character = 0 },
                },
                .newText = new_line,
            }});
            const doc_changes = try self.allocator.dupe(protocol.TextDocumentEdit, &[_]protocol.TextDocumentEdit{.{
                .textDocument = .{ .uri = uri },
                .edits = edits,
            }});
            try edit_allocs.append(self.allocator, doc_changes);

            try actions.append(self.allocator, .{
                .title = "Add Banjo Note",
                .kind = protocol.CodeActionKind.Refactor,
                .edit = .{ .documentChanges = doc_changes },
            });
        }

        try self.transport.writeTypedResponse(request.id, actions.items);
    }

    fn handleExecuteCommand(self: *Server, request: jsonrpc.Request) !void {
        log.info("handleExecuteCommand called", .{});
        const params = if (request.params) |p| blk: {
            const parsed = std.json.parseFromValue(
                protocol.ExecuteCommandParams,
                self.allocator,
                p,
                .{ .ignore_unknown_fields = true },
            ) catch {
                try self.transport.writeResponse(jsonrpc.Response.err(
                    request.id,
                    jsonrpc.Error.InvalidParams,
                    "Invalid execute command params",
                ));
                return;
            };
            break :blk parsed;
        } else {
            try self.transport.writeTypedResponse(request.id, null);
            return;
        };
        defer params.deinit();

        const cmd = params.value.command;

        const LspCommand = enum { createNote, showBacklinks };
        const command_map = std.StaticStringMap(LspCommand).initComptime(.{
            .{ "banjo.createNote", .createNote },
            .{ "banjo.showBacklinks", .showBacklinks },
        });

        if (command_map.get(cmd)) |command| switch (command) {
            .createNote => try self.executeCreateNote(params.value.arguments),
            .showBacklinks => {
                try self.executeShowBacklinks(request.id, params.value.arguments);
                return; // Response sent in executeShowBacklinks
            },
        };

        try self.transport.writeTypedResponse(request.id, null);
    }

    fn executeCreateNote(self: *Server, arguments: ?[]const std.json.Value) !void {
        const args = arguments orelse return;
        if (args.len < 2) return;

        const uri = if (args[0] == .string) args[0].string else return;
        const line = if (args[1] == .integer) castU32FromI64(args[1].integer) orelse return else return;
        const is_comment = if (args.len > 2 and args[2] == .bool) args[2].bool else true;

        const content = self.documents.get(uri) orelse return;
        const line_content = getLineContent(content, line - 1) orelse return;
        const file_path = uriToPath(uri) orelse return;
        const prefix = comments.getCommentPrefix(file_path);

        // Generate note ID
        const note_id = comments.generateNoteId();

        if (is_comment) {
            // Comment line: find prefix end, skip whitespace, insert note ID
            const trimmed = mem.trimLeft(u8, line_content, " \t");
            const leading_spaces = mem.indexOf(u8, line_content, trimmed) orelse 0;

            // Skip comment prefix chars (/, #, -, ;)
            var prefix_end: usize = 0;
            while (prefix_end < trimmed.len) : (prefix_end += 1) {
                const c = trimmed[prefix_end];
                if (c != '/' and c != '#' and c != '-' and c != ';') break;
            }
            // Skip whitespace after prefix
            var content_start = prefix_end;
            while (content_start < trimmed.len and (trimmed[content_start] == ' ' or trimmed[content_start] == '\t')) {
                content_start += 1;
            }

            const original_prefix = trimmed[0..prefix_end];
            const comment_text = trimmed[content_start..];

            // Build: <indent><original_prefix> @banjo[id] <content>
            const new_line = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s} @banjo[{s}] {s}",
                .{ line_content[0..leading_spaces], original_prefix, &note_id, comment_text },
            );
            defer self.allocator.free(new_line);
            try self.applyLineEdit(uri, line - 1, new_line);
        } else {
            // Code line: insert note comment above
            const indent = getIndent(line_content);
            const new_line = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s} @banjo[{s}] NOTE:\n",
                .{ indent, prefix, &note_id },
            );
            defer self.allocator.free(new_line);
            try self.applyInsertLine(uri, line - 1, new_line);
        }
    }

    fn executeShowBacklinks(self: *Server, request_id: ?jsonrpc.Request.Id, arguments: ?[]const std.json.Value) !void {
        const args = arguments orelse {
            try self.transport.writeTypedResponse(request_id, &[_]protocol.Location{});
            return;
        };
        if (args.len == 0 or args[0] != .string) {
            try self.transport.writeTypedResponse(request_id, &[_]protocol.Location{});
            return;
        }

        const note_id = args[0].string;

        // Get backlinks
        const backlink_ids = self.note_index.getBacklinks(note_id) orelse {
            try self.transport.writeTypedResponse(request_id, &[_]protocol.Location{});
            return;
        };

        // Build Location array
        var locations: std.ArrayListUnmanaged(protocol.Location) = .empty;
        defer locations.deinit(self.allocator);

        // Track URI allocations for cleanup
        var uris: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (uris.items) |u| self.allocator.free(u);
            uris.deinit(self.allocator);
        }

        for (backlink_ids) |bl_id| {
            if (self.note_index.getNote(bl_id)) |bl_note| {
                const bl_line: u32 = if (bl_note.line > 0) bl_note.line - 1 else 0;
                const bl_uri = try pathToUri(self.allocator, bl_note.file_path);
                try uris.append(self.allocator, bl_uri);
                try locations.append(self.allocator, .{
                    .uri = bl_uri,
                    .range = .{
                        .start = .{ .line = bl_line, .character = 0 },
                        .end = .{ .line = bl_line, .character = 1 },
                    },
                });
            }
        }

        try self.transport.writeTypedResponse(request_id, locations.items);
    }

    fn applyLineEdit(self: *Server, uri: []const u8, line: u32, new_text: []const u8) !void {
        // Build workspace/applyEdit request with proper JSON escaping
        var edit_writer: std.io.Writer.Allocating = .init(self.allocator);
        defer edit_writer.deinit();
        var jw: std.json.Stringify = .{ .writer = &edit_writer.writer };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write("workspace/applyEdit");
        try jw.objectField("params");
        try jw.beginObject();
        try jw.objectField("edit");
        try jw.beginObject();
        try jw.objectField("changes");
        try jw.beginObject();
        try jw.objectField(uri);
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("range");
        try jw.beginObject();
        try jw.objectField("start");
        try jw.write(.{ .line = line, .character = @as(u32, 0) });
        try jw.objectField("end");
        try jw.write(.{ .line = line, .character = @as(u32, 999) });
        try jw.endObject();
        try jw.objectField("newText");
        try jw.write(new_text);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();

        const edit_json = try edit_writer.toOwnedSlice();
        defer self.allocator.free(edit_json);
        try self.transport.writeMessage(edit_json);
    }

    fn applyInsertLine(self: *Server, uri: []const u8, line: u32, new_text: []const u8) !void {
        // Insert a new line at the given position (before existing line)
        var edit_writer: std.io.Writer.Allocating = .init(self.allocator);
        defer edit_writer.deinit();
        var jw: std.json.Stringify = .{ .writer = &edit_writer.writer };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write("workspace/applyEdit");
        try jw.objectField("params");
        try jw.beginObject();
        try jw.objectField("edit");
        try jw.beginObject();
        try jw.objectField("changes");
        try jw.beginObject();
        try jw.objectField(uri);
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("range");
        try jw.beginObject();
        try jw.objectField("start");
        try jw.write(.{ .line = line, .character = @as(u32, 0) });
        try jw.objectField("end");
        try jw.write(.{ .line = line, .character = @as(u32, 0) });
        try jw.endObject();
        try jw.objectField("newText");
        try jw.write(new_text);
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();

        const edit_json = try edit_writer.toOwnedSlice();
        defer self.allocator.free(edit_json);
        try self.transport.writeMessage(edit_json);
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, content: []const u8) !void {
        // Parse notes from content
        const notes = try comments.scanFileForNotes(self.allocator, content);
        defer {
            for (notes) |*n| @constCast(n).deinit(self.allocator);
            self.allocator.free(notes);
        }

        // Convert to diagnostics
        const owned = try diagnostics.notesToDiagnostics(self.allocator, notes, uri, &self.note_index);
        defer diagnostics.freeOwnedDiagnostics(self.allocator, owned);

        const diags = try diagnostics.extractDiagnostics(self.allocator, owned);
        defer self.allocator.free(diags);

        try self.transport.writeNotification("textDocument/publishDiagnostics", protocol.PublishDiagnosticsParams{
            .uri = uri,
            .diagnostics = diags,
        });
    }

    fn rebuildIndex(self: *Server) !void {
        // Clear and rebuild
        self.note_index.deinit();
        self.note_index = diagnostics.NoteIndex.init(self.allocator);

        // Scan all open documents
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            const uri = entry.key_ptr.*;
            const content = entry.value_ptr.*;
            const file_path = uriToPath(uri) orelse continue;

            const notes = comments.scanFileForNotes(self.allocator, content) catch continue;
            defer {
                for (notes) |*n| @constCast(n).deinit(self.allocator);
                self.allocator.free(notes);
            }

            for (notes) |note| {
                self.note_index.addNote(note, file_path) catch continue;
            }
        }
    }

    // line is 1-based (note metadata), convert to 0-based for LSP content.
    fn findNoteAtLine(self: *Server, content: []const u8, line: u32) ?comments.ParsedNote {
        return comments.parseNoteLine(self.allocator, getLineContent(content, line - 1) orelse return null, line) catch null;
    }
};

// line is 0-based (LSP positions).
fn getLineContent(content: []const u8, line: u32) ?[]const u8 {
    var current_line: u32 = 0;
    var start: usize = 0;

    for (content, 0..) |c, i| {
        if (c == '\n') {
            if (current_line == line) {
                return content[start..i];
            }
            current_line += 1;
            start = i + 1;
        }
    }

    // Last line without trailing newline
    if (current_line == line and start < content.len) {
        return content[start..];
    }

    return null;
}

fn getIndent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ' and c != '\t') {
            return line[0..i];
        }
    }
    return line; // All whitespace
}

fn isCommentLine(content: []const u8, line: u32) bool {
    const line_content = getLineContent(content, line - 1) orelse return false;
    const trimmed = mem.trimLeft(u8, line_content, " \t");

    for ([_][]const u8{ "//", "#", "--", ";", "<!--" }) |prefix| {
        if (mem.startsWith(u8, trimmed, prefix)) {
            // Make sure it's not already a banjo note
            return mem.indexOf(u8, trimmed, "@banjo[") == null;
        }
    }
    return false;
}

/// Find note ID at cursor position. Handles:
/// - @banjo[id] - returns id
/// - @[text](id) - returns id
fn findNoteIdAtPosition(line: []const u8, char: u32) ?[]const u8 {
    const pos = std.math.cast(usize, char) orelse return null;

    // Check for @banjo[id] patterns - find all of them
    var banjo_pos: usize = 0;
    while (mem.indexOfPos(u8, line, banjo_pos, "@banjo[")) |start| {
        const id_start = start + 7; // "@banjo[".len
        if (mem.indexOfPos(u8, line, id_start, "]")) |id_end| {
            if (pos >= start and pos <= id_end) {
                return line[id_start..id_end];
            }
            banjo_pos = id_end + 1;
        } else {
            banjo_pos = id_start;
        }
    }

    // Check for @[text](id) link patterns - find all of them
    var search_pos: usize = 0;
    while (search_pos < line.len) {
        const link_start = mem.indexOfPos(u8, line, search_pos, comments.link_prefix) orelse break;
        const mid = mem.indexOfPos(u8, line, link_start + 2, "](") orelse {
            search_pos = link_start + 2;
            continue;
        };
        const link_end = mem.indexOfPos(u8, line, mid + 2, ")") orelse {
            search_pos = mid + 2;
            continue;
        };

        if (pos >= link_start and pos <= link_end) {
            return line[mid + 2 .. link_end];
        }

        search_pos = link_end + 1;
    }

    return null;
}

fn uriToPath(uri: []const u8) ?[]const u8 {
    if (mem.startsWith(u8, uri, "file://")) {
        return uri[7..];
    }
    return null;
}

fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

/// Check if line contains TODO, FIXME, BUG, HACK, XXX patterns
fn hasTodoPattern(line: []const u8) ?[]const u8 {
    const patterns = [_][]const u8{ "TODO:", "FIXME:", "BUG:", "HACK:", "XXX:", "NOTE:" };
    const upper_line = blk: {
        var buf: [256]u8 = undefined;
        const len = @min(line.len, buf.len);
        for (line[0..len], 0..) |c, i| {
            buf[i] = std.ascii.toUpper(c);
        }
        break :blk buf[0..len];
    };

    for (patterns) |pattern| {
        if (mem.indexOf(u8, upper_line, pattern) != null) {
            return pattern;
        }
    }
    return null;
}

fn castU32(value: usize) ?u32 {
    return std.math.cast(u32, value);
}

fn castU32FromI64(value: i64) ?u32 {
    return std.math.cast(u32, value);
}

fn appendNoteCompletion(
    allocator: Allocator,
    items: *std.ArrayListUnmanaged(protocol.CompletionItem),
    allocated_strings: *std.ArrayListUnmanaged([]const u8),
    note_id: []const u8,
    note_info: diagnostics.NoteIndex.NoteInfo,
    detail: []const u8,
    sort_prefix: []const u8,
) !void {
    const summary_text = summary.getSummary(note_info.content, .{ .max_len = 40, .prefer_word_boundary = true });
    const insertText = try std.fmt.allocPrint(allocator, "{s}]({s})", .{ summary_text, note_id });
    try allocated_strings.append(allocator, insertText);
    const sortText = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sort_prefix, note_id });
    try allocated_strings.append(allocator, sortText);
    try items.append(allocator, .{
        .label = summary_text,
        .kind = 6, // Variable
        .detail = detail,
        .insertText = insertText,
        .sortText = sortText,
    });
}

const LineContext = struct {
    before: []const u8,
    current: []const u8,
    after: []const u8,
};

fn getLineContext(content: []const u8, line_num: u32, context_lines: u32) LineContext {
    var lines_iter = mem.splitScalar(u8, content, '\n');
    var current_line: u32 = 1;
    var before_start: usize = 0;
    var before_end: usize = 0;
    var line_start: usize = 0;
    var line_end: usize = 0;
    var after_start: usize = 0;
    var after_end: usize = 0;
    var pos: usize = 0;
    const before_target = line_num -| context_lines;
    const prev_line = line_num -| 1;
    const next_line = line_num +| 1;
    const after_target = line_num +| context_lines;

    while (lines_iter.next()) |line| {
        const next_pos = pos + line.len + 1;

        if (current_line == before_target and line_num > context_lines) {
            before_start = pos;
        }
        if (current_line == prev_line) {
            before_end = pos + line.len;
        }
        if (current_line == line_num) {
            line_start = pos;
            line_end = pos + line.len;
        }
        if (current_line == next_line) {
            after_start = pos;
        }
        if (current_line == after_target) {
            after_end = pos + line.len;
        }

        pos = next_pos;
        current_line += 1;
    }

    return .{
        .before = if (before_end > before_start) content[before_start..before_end] else "",
        .current = if (line_end > line_start) content[line_start..line_end] else "",
        .after = if (after_end > after_start) content[after_start..after_end] else "",
    };
}

//
// Tests
//

const testing = std.testing;

test "uriToPath strips file:// prefix" {
    try testing.expectEqualStrings("/home/user/test.zig", uriToPath("file:///home/user/test.zig").?);
}

test "uriToPath returns null for non-file URIs" {
    try testing.expect(uriToPath("http://example.com") == null);
}

test "getLineContent returns correct line" {
    const content = "line 0\nline 1\nline 2";
    try testing.expectEqualStrings("line 0", getLineContent(content, 0).?);
    try testing.expectEqualStrings("line 1", getLineContent(content, 1).?);
    try testing.expectEqualStrings("line 2", getLineContent(content, 2).?);
    try testing.expect(getLineContent(content, 3) == null);
}

test "isCommentLine detects comments" {
    const content = "code\n// comment\n# python\nmore code";
    try testing.expect(!isCommentLine(content, 1)); // code
    try testing.expect(isCommentLine(content, 2)); // // comment
    try testing.expect(isCommentLine(content, 3)); // # python
    try testing.expect(!isCommentLine(content, 4)); // more code
}

test "isCommentLine excludes banjo notes" {
    const content = "// @banjo[abc] note\n// regular comment";
    try testing.expect(!isCommentLine(content, 1)); // already a note
    try testing.expect(isCommentLine(content, 2)); // can be converted
}

test "Server initializes correctly" {
    var input = std.io.fixedBufferStream("");
    var output_buf: [1024]u8 = undefined;
    var output = std.io.fixedBufferStream(&output_buf);

    var server = Server.init(testing.allocator, input.reader().any(), output.writer().any());
    defer server.deinit();

    try testing.expect(server.root_uri == null);
    try testing.expect(!server.initialized);
}
