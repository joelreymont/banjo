const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const protocol = @import("protocol.zig");
const comments = @import("../notes/comments.zig");
const summary = @import("summary.zig");
const lsp_uri = @import("uri.zig");

/// Diagnostic with ownership info for deferred cleanup
pub const OwnedDiagnostic = struct {
    diagnostic: protocol.Diagnostic,
    owned_message: []const u8,
    owned_related: ?[]protocol.DiagnosticRelatedInformation,
    owned_uris: ?[]const []const u8, // URIs in related info

    pub fn deinit(self: *OwnedDiagnostic, allocator: Allocator) void {
        allocator.free(self.owned_message);
        if (self.owned_related) |related| {
            for (related) |r| {
                allocator.free(r.message);
            }
            allocator.free(related);
        }
        if (self.owned_uris) |uris| {
            for (uris) |u| {
                allocator.free(u);
            }
            allocator.free(uris);
        }
    }
};

/// Index of all notes for backlink lookup
pub const NoteIndex = struct {
    pub const NoteInfo = struct {
        file_path: []const u8,
        line: u32,
        content: []const u8,
    };

    const BacklinkList = std.ArrayListUnmanaged([]const u8);
    const NotesMap = std.StringHashMap(NoteInfo);
    const BacklinksMap = std.StringHashMap(BacklinkList);
    const FileNotesMap = std.StringHashMap(std.ArrayListUnmanaged([]const u8));

    notes: NotesMap,
    backlinks: BacklinksMap,
    file_notes: FileNotesMap,
    allocator: Allocator,

    pub fn init(allocator: Allocator) NoteIndex {
        return .{
            .notes = NotesMap.init(allocator),
            .backlinks = BacklinksMap.init(allocator),
            .file_notes = FileNotesMap.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NoteIndex) void {
        // Free note info
        var note_it = self.notes.iterator();
        while (note_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.file_path);
            self.allocator.free(entry.value_ptr.content);
        }
        self.notes.deinit();

        // Free backlinks
        var bl_it = self.backlinks.iterator();
        while (bl_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |id| {
                self.allocator.free(id);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.backlinks.deinit();

        // Free file note map
        var file_it = self.file_notes.iterator();
        while (file_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.file_notes.deinit();
    }

    /// Add a note to the index
    pub fn addNote(self: *NoteIndex, note: comments.ParsedNote, file_path: []const u8) !void {
        // Check for existing note with same ID and free it
        if (self.notes.fetchRemove(note.id)) |old| {
            self.removeNoteFromFileMap(old.value.file_path, old.key);
            self.allocator.free(old.key);
            self.allocator.free(old.value.file_path);
            self.allocator.free(old.value.content);
        }
        try self.removeBacklinksForSource(note.id);

        const id = try self.allocator.dupe(u8, note.id);
        errdefer self.allocator.free(id);

        const path = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(path);

        const content = try self.allocator.dupe(u8, note.content);
        errdefer self.allocator.free(content);

        // Index backlinks BEFORE adding note to map (so errdefers work correctly)
        for (note.links) |target_id| {
            // Check if target already exists before allocating
            if (self.backlinks.getPtr(target_id)) |list| {
                if (listContains(list.items, note.id)) continue;
                const source_id = try self.allocator.dupe(u8, note.id);
                list.append(self.allocator, source_id) catch |err| {
                    self.allocator.free(source_id);
                    return err;
                };
            } else {
                // New target, need to allocate key
                const source_id = try self.allocator.dupe(u8, note.id);
                const target = try self.allocator.dupe(u8, target_id);
                const result = self.backlinks.getOrPut(target) catch |e| {
                    self.allocator.free(target);
                    self.allocator.free(source_id);
                    return e;
                };
                result.value_ptr.* = .empty;
                result.value_ptr.append(self.allocator, source_id) catch |e| {
                    // Remove and free the entry we just added
                    self.allocator.free(source_id);
                    _ = self.backlinks.remove(target);
                    self.allocator.free(target);
                    return e;
                };
            }
        }

        // Add note to map last (after backlinks processed successfully)
        try self.notes.put(id, .{
            .file_path = path,
            .line = note.line,
            .content = content,
        });
        try self.addNoteToFileMap(path, id);
    }

    pub fn removeNotesByFile(self: *NoteIndex, file_path: []const u8) !void {
        if (self.file_notes.fetchRemove(file_path)) |removed| {
            var list = removed.value;
            for (list.items) |note_id| {
                if (self.notes.fetchRemove(note_id)) |note| {
                    try self.removeBacklinksForSource(note.key);
                    self.allocator.free(note.key);
                    self.allocator.free(note.value.file_path);
                    self.allocator.free(note.value.content);
                }
            }
            list.deinit(self.allocator);
            self.allocator.free(removed.key);
        }
    }

    fn listContains(list: []const []const u8, needle: []const u8) bool {
        for (list) |item| {
            if (mem.eql(u8, item, needle)) return true;
        }
        return false;
    }

    fn addNoteToFileMap(self: *NoteIndex, file_path: []const u8, note_id: []const u8) !void {
        if (self.file_notes.getPtr(file_path)) |list| {
            if (!listContains(list.items, note_id)) {
                try list.append(self.allocator, note_id);
            }
            return;
        }

        const key = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(key);

        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        try list.append(self.allocator, note_id);
        errdefer list.deinit(self.allocator);

        try self.file_notes.put(key, list);
    }

    fn removeNoteFromFileMap(self: *NoteIndex, file_path: []const u8, note_id: []const u8) void {
        const list = self.file_notes.getPtr(file_path) orelse return;
        var i: usize = 0;
        while (i < list.items.len) {
            if (mem.eql(u8, list.items[i], note_id)) {
                _ = list.orderedRemove(i);
                break;
            }
            i += 1;
        }
        if (list.items.len == 0) {
            if (self.file_notes.fetchRemove(file_path)) |removed| {
                var list_removed = removed.value;
                list_removed.deinit(self.allocator);
                self.allocator.free(removed.key);
            }
        }
    }

    fn removeBacklinksForSource(self: *NoteIndex, source_id: []const u8) !void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.backlinks.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr.*;
            var i: usize = 0;
            while (i < list.items.len) {
                if (mem.eql(u8, list.items[i], source_id)) {
                    self.allocator.free(list.items[i]);
                    _ = list.orderedRemove(i);
                    continue;
                }
                i += 1;
            }
            if (list.items.len == 0) {
                try to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            if (self.backlinks.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                var list = removed.value;
                list.deinit(self.allocator);
            }
        }
    }

    /// Get backlinks to a note (notes that link TO this note)
    pub fn getBacklinks(self: *NoteIndex, note_id: []const u8) ?[]const []const u8 {
        if (self.backlinks.get(note_id)) |list| {
            return list.items;
        }
        return null;
    }

    /// Get note info by ID
    pub fn getNote(self: *NoteIndex, note_id: []const u8) ?NoteInfo {
        return self.notes.get(note_id);
    }
};

/// Convert a parsed note to an LSP diagnostic
pub fn noteToDiagnostic(
    allocator: Allocator,
    note: comments.ParsedNote,
    _: []const u8, // file_uri - reserved for future use
    index: ?*NoteIndex,
) !OwnedDiagnostic {
    // 0-indexed line for LSP
    const line: u32 = if (note.line > 0) note.line - 1 else 0;

    // Get summary (first 80 chars)
    const summary_text = summary.getSummary(note.content, .{ .max_len = 80, .prefer_word_boundary = false });

    // Format message
    const message = try std.fmt.allocPrint(allocator, "Note: {s}", .{summary_text});
    errdefer allocator.free(message);

    // Build related information for backlinks
    var owned_related: ?[]protocol.DiagnosticRelatedInformation = null;
    var owned_uris: ?[]const []const u8 = null;
    if (index) |idx| {
        if (idx.getBacklinks(note.id)) |backlink_ids| {
            var related = try allocator.alloc(protocol.DiagnosticRelatedInformation, backlink_ids.len);
            var uris = try allocator.alloc([]const u8, backlink_ids.len);
            var valid_count: usize = 0;

            errdefer {
                // Clean up partial allocations on error
                for (0..valid_count) |i| {
                    allocator.free(related[i].message);
                    allocator.free(uris[i]);
                }
                allocator.free(related);
                allocator.free(uris);
            }

            for (backlink_ids) |bl_id| {
                if (idx.getNote(bl_id)) |bl_note| {
                    const bl_line: u32 = if (bl_note.line > 0) bl_note.line - 1 else 0;
                    const bl_summary = summary.getSummary(bl_note.content, .{ .max_len = 80, .prefer_word_boundary = false });
                    const bl_msg = try std.fmt.allocPrint(allocator, "Linked from: {s}", .{bl_summary});
                    errdefer allocator.free(bl_msg);
                    const bl_uri = try lsp_uri.pathToUri(allocator, bl_note.file_path);

                    uris[valid_count] = bl_uri;
                    related[valid_count] = .{
                        .location = .{
                            .uri = bl_uri,
                            .range = .{
                                .start = .{ .line = bl_line, .character = 0 },
                                .end = .{ .line = bl_line, .character = 1 },
                            },
                        },
                        .message = bl_msg,
                    };
                    valid_count += 1;
                }
            }

            if (valid_count > 0) {
                owned_related = related[0..valid_count];
                owned_uris = uris[0..valid_count];
            } else {
                allocator.free(related);
                allocator.free(uris);
            }
        }
    }

    return .{
        .diagnostic = .{
            .range = .{
                .start = .{ .line = line, .character = 0 },
                .end = .{ .line = line, .character = 1 },
            },
            .severity = .Information,
            .source = "banjo",
            .code = if (note.id.len >= 8) note.id[0..8] else note.id,
            .message = message,
            .relatedInformation = owned_related,
        },
        .owned_message = message,
        .owned_related = owned_related,
        .owned_uris = owned_uris,
    };
}

/// Convert multiple notes to diagnostics
pub fn notesToDiagnostics(
    allocator: Allocator,
    notes: []const comments.ParsedNote,
    file_uri: []const u8,
    index: ?*NoteIndex,
) ![]OwnedDiagnostic {
    if (notes.len == 0) return try allocator.alloc(OwnedDiagnostic, 0);

    var result = try allocator.alloc(OwnedDiagnostic, notes.len);
    var initialized: usize = 0;
    errdefer {
        // Only free initialized elements
        for (result[0..initialized]) |*d| d.deinit(allocator);
        allocator.free(result);
    }

    for (notes, 0..) |note, i| {
        result[i] = try noteToDiagnostic(allocator, note, file_uri, index);
        initialized += 1;
    }

    return result;
}

/// Free owned diagnostics slice
pub fn freeOwnedDiagnostics(allocator: Allocator, owned: []OwnedDiagnostic) void {
    for (owned) |*d| d.deinit(allocator);
    allocator.free(owned);
}

/// Extract diagnostic structs for serialization
pub fn extractDiagnostics(allocator: Allocator, owned: []const OwnedDiagnostic) ![]protocol.Diagnostic {
    const result = try allocator.alloc(protocol.Diagnostic, owned.len);
    for (owned, 0..) |od, i| {
        result[i] = od.diagnostic;
    }
    return result;
}

//
// Tests
//

const testing = std.testing;

test "noteToDiagnostic creates info diagnostic" {
    const note = comments.ParsedNote{
        .id = "12345678abcd",
        .line = 10,
        .content = "Test note content",
        .links = &.{},
    };

    var owned = try noteToDiagnostic(testing.allocator, note, "file:///test.zig", null);
    defer owned.deinit(testing.allocator);
    const snapshot = .{
        .severity = @tagName(owned.diagnostic.severity.?),
        .line = owned.diagnostic.range.start.line,
        .source = owned.diagnostic.source.?,
        .message = owned.diagnostic.message,
    };
    try (ohsnap{}).snap(@src(),
        \\lsp.diagnostics.test.noteToDiagnostic creates info diagnostic__struct_<^\d+$>
        \\  .severity: [:0]const u8
        \\    "Information"
        \\  .line: u32 = 9
        \\  .source: []const u8
        \\    "banjo"
        \\  .message: []const u8
        \\    "Note: Test note content"
    ).expectEqual(snapshot);
}

test "getSummary truncates long text" {
    const long_text = "a" ** 100;
    const summary_text = summary.getSummary(long_text, .{ .max_len = 80, .prefer_word_boundary = false });
    try (ohsnap{}).snap(@src(),
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    ).diff(summary_text, true);
}

test "getSummary stops at newline" {
    const text = "First line\nSecond line";
    const summary_text = summary.getSummary(text, .{ .max_len = 80, .prefer_word_boundary = false });
    try (ohsnap{}).snap(@src(),
        \\First line
    ).diff(summary_text, true);
}

test "NoteIndex tracks backlinks" {
    var index = NoteIndex.init(testing.allocator);
    defer index.deinit();

    // Note A links to note B
    const note_a = comments.ParsedNote{
        .id = "note-a",
        .line = 1,
        .content = "Links to [[B][note-b]]",
        .links = &[_][]const u8{"note-b"},
    };
    try index.addNote(note_a, "/test.zig");

    // Note B exists
    const note_b = comments.ParsedNote{
        .id = "note-b",
        .line = 5,
        .content = "Target note",
        .links = &.{},
    };
    try index.addNote(note_b, "/test.zig");

    // Check backlinks to note-b
    const backlinks = index.getBacklinks("note-b").?;
    const snapshot = .{ .backlinks = backlinks };
    try (ohsnap{}).snap(@src(),
        \\lsp.diagnostics.test.NoteIndex tracks backlinks__struct_<^\d+$>
        \\  .backlinks: []const []const u8
        \\    [0]: []const u8
        \\      "note-a"
    ).expectEqual(snapshot);
}

test "NoteIndex avoids duplicate backlinks" {
    var index = NoteIndex.init(testing.allocator);
    defer index.deinit();

    const note_a = comments.ParsedNote{
        .id = "note-a",
        .line = 1,
        .content = "Links to [[B][note-b]]",
        .links = &[_][]const u8{"note-b"},
    };
    try index.addNote(note_a, "/test.zig");
    try index.addNote(note_a, "/test.zig");

    const backlinks = index.getBacklinks("note-b").?;
    const snapshot = .{ .backlinks = backlinks };
    try (ohsnap{}).snap(@src(),
        \\lsp.diagnostics.test.NoteIndex avoids duplicate backlinks__struct_<^\d+$>
        \\  .backlinks: []const []const u8
        \\    [0]: []const u8
        \\      "note-a"
    ).expectEqual(snapshot);
}

test "NoteIndex removeNotesByFile clears notes and backlinks" {
    var index = NoteIndex.init(testing.allocator);
    defer index.deinit();

    var note_a = (try comments.parseNoteLine(testing.allocator, "// @banjo[a] Link @[b](b)", 1)).?;
    var note_b = (try comments.parseNoteLine(testing.allocator, "// @banjo[b] Target", 2)).?;
    defer note_a.deinit(testing.allocator);
    defer note_b.deinit(testing.allocator);

    try index.addNote(note_a, "/tmp/a.zig");
    try index.addNote(note_b, "/tmp/b.zig");

    try index.removeNotesByFile("/tmp/a.zig");

    const backlinks = index.getBacklinks("b") orelse &.{};
    const snapshot = .{
        .note_a_present = index.getNote("a") != null,
        .backlinks = backlinks,
    };
    try (ohsnap{}).snap(@src(),
        \\lsp.diagnostics.test.NoteIndex removeNotesByFile clears notes and backlinks__struct_<^\d+$>
        \\  .note_a_present: bool = false
        \\  .backlinks: []const []const u8
        \\    (empty)
    ).expectEqual(snapshot);
}

// Snapshot tests
const ohsnap = @import("ohsnap");

test "snapshot: note diagnostic JSON" {
    const note = comments.ParsedNote{
        .id = "abc12345defg",
        .line = 42,
        .content = "TODO: refactor this function",
        .links = &.{},
    };

    var owned = try noteToDiagnostic(testing.allocator, note, "file:///src/main.zig", null);
    defer owned.deinit(testing.allocator);

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(owned.diagnostic);
    const json = try out.toOwnedSlice();
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(
        @src(),
        \\{"range":{"start":{"line":41,"character":0},"end":{"line":41,"character":1}},"severity":3,"code":"abc12345","source":"banjo","message":"Note: TODO: refactor this function"}
        ,
    ).diff(json, true);
}
