const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const protocol = @import("protocol.zig");
const comments = @import("../notes/comments.zig");

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

fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

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

    notes: NotesMap,
    backlinks: BacklinksMap,
    allocator: Allocator,

    pub fn init(allocator: Allocator) NoteIndex {
        return .{
            .notes = NotesMap.init(allocator),
            .backlinks = BacklinksMap.init(allocator),
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
    }

    /// Add a note to the index
    pub fn addNote(self: *NoteIndex, note: comments.ParsedNote, file_path: []const u8) !void {
        // Check for existing note with same ID and free it
        if (self.notes.fetchRemove(note.id)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.file_path);
            self.allocator.free(old.value.content);
        }

        const id = try self.allocator.dupe(u8, note.id);
        errdefer self.allocator.free(id);

        const path = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(path);

        const content = try self.allocator.dupe(u8, note.content);
        errdefer self.allocator.free(content);

        // Index backlinks BEFORE adding note to map (so errdefers work correctly)
        for (note.links) |target_id| {
            const source_id = try self.allocator.dupe(u8, note.id);
            errdefer self.allocator.free(source_id);

            // Check if target already exists before allocating
            if (self.backlinks.getPtr(target_id)) |list| {
                // Target exists, just append source
                try list.append(self.allocator, source_id);
            } else {
                // New target, need to allocate key
                const target = try self.allocator.dupe(u8, target_id);
                const result = self.backlinks.getOrPut(target) catch |e| {
                    self.allocator.free(target);
                    return e;
                };
                result.value_ptr.* = .empty;
                result.value_ptr.append(self.allocator, source_id) catch |e| {
                    // Remove and free the entry we just added
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
    const summary = getSummary(note.content);

    // Format message
    const message = try std.fmt.allocPrint(allocator, "Note: {s}", .{summary});
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
                    const bl_msg = try std.fmt.allocPrint(allocator, "Linked from: {s}", .{getSummary(bl_note.content)});
                    errdefer allocator.free(bl_msg);
                    const bl_uri = try pathToUri(allocator, bl_note.file_path);

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

fn getSummary(text: []const u8) []const u8 {
    // Get first line, max 80 chars
    var end: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            end = i;
            break;
        }
    } else {
        end = text.len;
    }

    const max_len = 80;
    if (end > max_len) {
        return text[0..max_len];
    }
    return text[0..end];
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

    try testing.expectEqual(protocol.DiagnosticSeverity.Information, owned.diagnostic.severity.?);
    try testing.expectEqual(@as(u32, 9), owned.diagnostic.range.start.line); // 0-indexed
    try testing.expectEqualStrings("banjo", owned.diagnostic.source.?);
    try testing.expect(mem.startsWith(u8, owned.diagnostic.message, "Note:"));
}

test "getSummary truncates long text" {
    const long_text = "a" ** 100;
    const summary = getSummary(long_text);
    try testing.expectEqual(@as(usize, 80), summary.len);
}

test "getSummary stops at newline" {
    const text = "First line\nSecond line";
    const summary = getSummary(text);
    try testing.expectEqualStrings("First line", summary);
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
    try testing.expectEqual(@as(usize, 1), backlinks.len);
    try testing.expectEqualStrings("note-a", backlinks[0]);
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
