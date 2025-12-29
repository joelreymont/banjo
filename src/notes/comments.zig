const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const link_prefix = "@[";

/// Parsed note from a comment
pub const ParsedNote = struct {
    id: []const u8,
    line: u32,
    content: []const u8,
    /// Links found in content: @[summary](target-id)
    links: []const []const u8,

    pub fn deinit(self: *ParsedNote, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.content);
        for (self.links) |link| {
            allocator.free(link);
        }
        allocator.free(self.links);
    }
};

/// Comment prefix patterns for different languages
const CommentPrefix = struct {
    start: []const u8,
    end: ?[]const u8 = null, // For block comments like <!-- -->
};

const comment_prefixes = [_]CommentPrefix{
    .{ .start = "//" }, // C, C++, Zig, Rust, Go, Java, JS, TS
    .{ .start = "#" }, // Python, Ruby, Shell, YAML
    .{ .start = "--" }, // Lua, SQL, Haskell
    .{ .start = ";" }, // Lisp, Clojure, Assembly
    .{ .start = "<!--", .end = "-->" }, // HTML, XML, Markdown
};

const banjo_marker = "@banjo[";

fn stripCommentPrefix(line: []const u8) ?[]const u8 {
    const trimmed = mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0) return null;

    if (mem.startsWith(u8, trimmed, "<!--")) {
        var pos: usize = 4;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) pos += 1;
        var end = trimmed.len;
        if (mem.endsWith(u8, trimmed, "-->")) {
            end -= 3;
        }
        return mem.trim(u8, trimmed[pos..end], " \t");
    }

    if (mem.startsWith(u8, trimmed, "//")) {
        var pos: usize = 2;
        while (pos < trimmed.len and (trimmed[pos] == '/' or trimmed[pos] == '!')) pos += 1;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) pos += 1;
        return trimmed[pos..];
    }

    if (mem.startsWith(u8, trimmed, "--")) {
        var pos: usize = 2;
        while (pos < trimmed.len and trimmed[pos] == '-') pos += 1;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) pos += 1;
        return trimmed[pos..];
    }

    if (mem.startsWith(u8, trimmed, "#")) {
        var pos: usize = 1;
        while (pos < trimmed.len and trimmed[pos] == '#') pos += 1;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) pos += 1;
        return trimmed[pos..];
    }

    if (mem.startsWith(u8, trimmed, ";")) {
        var pos: usize = 1;
        while (pos < trimmed.len and trimmed[pos] == ';') pos += 1;
        while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) pos += 1;
        return trimmed[pos..];
    }

    return null;
}

fn parseLinksInto(allocator: Allocator, links: *std.ArrayListUnmanaged([]const u8), content: []const u8) !void {
    var pos: usize = 0;
    while (pos < content.len) {
        const link_start = mem.indexOfPos(u8, content, pos, link_prefix) orelse break;
        const mid = mem.indexOfPos(u8, content, link_start + 2, "](") orelse {
            pos = link_start + 2;
            continue;
        };
        const link_end = mem.indexOfPos(u8, content, mid + 2, ")") orelse {
            pos = mid + 2;
            continue;
        };

        const target_id = content[mid + 2 .. link_end];
        try links.append(allocator, try allocator.dupe(u8, target_id));
        pos = link_end + 1;
    }
}

/// Parse a single line for a @banjo note comment
/// Returns null if line doesn't contain a banjo note
pub fn parseNoteLine(allocator: Allocator, line: []const u8, line_number: u32) !?ParsedNote {
    // Find @banjo[ marker
    const marker_start = mem.indexOf(u8, line, banjo_marker) orelse return null;

    // Find the note ID (between [ and ])
    const id_start = marker_start + banjo_marker.len;
    const id_end = mem.indexOfPos(u8, line, id_start, "]") orelse return null;

    if (id_end <= id_start) return null;

    const id = try allocator.dupe(u8, line[id_start..id_end]);
    errdefer allocator.free(id);

    // Content is after "]" - skip whitespace
    var cs = id_end + 1;
    while (cs < line.len and (line[cs] == ' ' or line[cs] == '\t')) cs += 1;
    const content = line[cs..];

    const duped_content = try allocator.dupe(u8, content);
    errdefer allocator.free(duped_content);

    // Parse links from content
    const links = try parseLinks(allocator, duped_content);

    return ParsedNote{
        .id = id,
        .line = line_number,
        .content = duped_content,
        .links = links,
    };
}

/// Parse @[display](target-id) links from content
fn parseLinks(allocator: Allocator, content: []const u8) ![]const []const u8 {
    var links: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (links.items) |link| allocator.free(link);
        links.deinit(allocator);
    }

    try parseLinksInto(allocator, &links, content);

    return try links.toOwnedSlice(allocator);
}

/// Scan file content for all @banjo note comments
pub fn scanFileForNotes(allocator: Allocator, content: []const u8) ![]ParsedNote {
    var notes: std.ArrayListUnmanaged(ParsedNote) = .empty;
    errdefer {
        for (notes.items) |*note| note.deinit(allocator);
        notes.deinit(allocator);
    }

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var line_iter = mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        try lines.append(allocator, line);
    }

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        const line_number: u32 = @intCast(i + 1);
        if (try parseNoteLine(allocator, line, line_number)) |note_parsed| {
            var note = note_parsed;
            errdefer note.deinit(allocator);

            var content_buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer content_buf.deinit(allocator);
            try content_buf.appendSlice(allocator, note.content);

            var link_list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer link_list.deinit(allocator);
            try link_list.appendSlice(allocator, note.links);
            const initial_links_len = link_list.items.len;
            errdefer {
                for (link_list.items[initial_links_len..]) |link| allocator.free(link);
            }

            var j = i + 1;
            while (j < lines.items.len) : (j += 1) {
                const next_line = lines.items[j];
                if (mem.indexOf(u8, next_line, banjo_marker) != null) break;
                const comment_content = stripCommentPrefix(next_line) orelse break;
                if (comment_content.len > 0) {
                    if (content_buf.items.len > 0) try content_buf.append(allocator, '\n');
                    try content_buf.appendSlice(allocator, comment_content);
                }
                try parseLinksInto(allocator, &link_list, comment_content);
            }

            if (content_buf.items.len > 0) {
                const new_content = try content_buf.toOwnedSlice(allocator);
                allocator.free(note.content);
                note.content = new_content;
            }

            const new_links = try link_list.toOwnedSlice(allocator);
            allocator.free(note.links);
            note.links = new_links;

            try notes.append(allocator, note);
            i = j - 1;
        }
    }

    return try notes.toOwnedSlice(allocator);
}

/// Generate a new unique note ID
pub fn generateNoteId() [12]u8 {
    // Combine timestamp (8 chars) + crypto random (4 chars) to avoid collisions
    const timestamp_ms = std.time.milliTimestamp();
    const timestamp_u64: u64 = if (timestamp_ms < 0) 0 else @intCast(timestamp_ms);
    const timestamp_low: u32 = @truncate(timestamp_u64); // compact ID; low bits are sufficient for uniqueness
    var random_bytes: [2]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const random = std.mem.readInt(u16, &random_bytes, .little);
    var buf: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>8}{x:0>4}", .{
        timestamp_low,
        random,
    }) catch unreachable;
    return buf;
}

/// Format a note comment for insertion
pub fn formatNoteComment(
    allocator: Allocator,
    id: []const u8,
    content: []const u8,
    comment_prefix: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} @banjo[{s}] {s}", .{
        comment_prefix,
        id,
        content,
    });
}

/// Insert text at a specific line in a file (atomic write via temp file)
/// file_path should be a canonical path (use realpathAlloc before calling)
pub fn insertAtLine(allocator: Allocator, file_path: []const u8, line_num: u32, text: []const u8) !void {
    // Line 0 is invalid (lines are 1-indexed)
    if (line_num == 0) return error.LineOutOfBounds;

    // Resolve to a canonical path and use it for the actual file open.
    const real_path = std.fs.cwd().realpathAlloc(allocator, file_path) catch return error.FileNotFound;
    defer allocator.free(real_path);
    if (!std.mem.eql(u8, real_path, file_path)) return error.PathChanged;

    // Read file
    const file = std.fs.openFileAbsolute(real_path, .{ .mode = .read_only }) catch return error.FileNotFound;
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    file.close();
    defer allocator.free(content);

    // Count lines and find insertion point
    var line_start: usize = 0;
    var current_line: u32 = 1;
    var total_lines: u32 = 1;
    var found = false;

    for (content, 0..) |c, i| {
        if (!found and current_line == line_num) {
            line_start = i;
            found = true;
        }
        if (c == '\n') {
            current_line += 1;
            total_lines += 1;
        }
    }

    // Handle insertion at end of file
    if (!found) {
        if (line_num == total_lines + 1) {
            line_start = content.len;
        } else {
            return error.LineOutOfBounds;
        }
    }

    // Build new content
    var new_content: std.ArrayListUnmanaged(u8) = .empty;
    defer new_content.deinit(allocator);
    try new_content.appendSlice(allocator, content[0..line_start]);
    try new_content.appendSlice(allocator, text);
    try new_content.appendSlice(allocator, content[line_start..]);

    // Atomic write: write to temp file with random suffix, then rename
    var random_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.banjo.{x:0>8}.tmp", .{
        file_path,
        std.mem.readInt(u32, &random_bytes, .little),
    });
    defer allocator.free(tmp_path);

    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    tmp_file.writeAll(new_content.items) catch |err| {
        tmp_file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return err;
    };
    tmp_file.close();

    // Atomic rename
    std.fs.renameAbsolute(tmp_path, file_path) catch |err| {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return err;
    };
}

/// Get the appropriate comment prefix for a file extension
pub fn getCommentPrefix(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);

    const prefix_map = std.StaticStringMap([]const u8).initComptime(.{
        // Hash comments
        .{ ".py", "#" },
        .{ ".rb", "#" },
        .{ ".sh", "#" },
        .{ ".yaml", "#" },
        .{ ".yml", "#" },
        // Double-dash comments
        .{ ".lua", "--" },
        .{ ".sql", "--" },
        // Semicolon comments
        .{ ".el", ";" },
        .{ ".lisp", ";" },
        .{ ".clj", ";" },
    });

    return prefix_map.get(ext) orelse "//";
}

//
// Tests
//

const testing = std.testing;

test "parseNoteLine extracts note ID and content" {
    const alloc = testing.allocator;
    var note = (try parseNoteLine(alloc, "// @banjo[note-123] TODO fix this", 5)).?;
    defer note.deinit(alloc);

    try testing.expectEqualStrings("note-123", note.id);
    try testing.expectEqualStrings("TODO fix this", note.content);
    try testing.expectEqual(@as(u32, 5), note.line);
}

test "parseNoteLine returns null for non-note lines" {
    const alloc = testing.allocator;
    try testing.expect(try parseNoteLine(alloc, "// regular comment", 1) == null);
    try testing.expect(try parseNoteLine(alloc, "const x = 5;", 1) == null);
    try testing.expect(try parseNoteLine(alloc, "", 1) == null);
}

test "parseNoteLine handles different comment styles" {
    const alloc = testing.allocator;

    var note1 = (try parseNoteLine(alloc, "# @banjo[py-note] Python note", 1)).?;
    defer note1.deinit(alloc);
    try testing.expectEqualStrings("py-note", note1.id);

    var note2 = (try parseNoteLine(alloc, "-- @banjo[sql-note] SQL note", 1)).?;
    defer note2.deinit(alloc);
    try testing.expectEqualStrings("sql-note", note2.id);
}

test "parseNoteLine extracts links" {
    const alloc = testing.allocator;
    var note = (try parseNoteLine(alloc, "// @banjo[note-1] See @[other note](note-2) and @[third](note-3)", 1)).?;
    defer note.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), note.links.len);
    try testing.expectEqualStrings("note-2", note.links[0]);
    try testing.expectEqualStrings("note-3", note.links[1]);
}

test "scanFileForNotes finds all notes" {
    const alloc = testing.allocator;
    const content =
        \\const std = @import("std");
        \\// @banjo[note-1] First note
        \\pub fn main() void {
        \\    // @banjo[note-2] Second note
        \\}
    ;

    const notes = try scanFileForNotes(alloc, content);
    defer {
        for (notes) |*n| @constCast(n).deinit(alloc);
        alloc.free(notes);
    }

    try testing.expectEqual(@as(usize, 2), notes.len);
    try testing.expectEqualStrings("note-1", notes[0].id);
    try testing.expectEqual(@as(u32, 2), notes[0].line);
    try testing.expectEqualStrings("note-2", notes[1].id);
    try testing.expectEqual(@as(u32, 4), notes[1].line);
}

test "scanFileForNotes captures links in comment blocks" {
    const alloc = testing.allocator;
    const content =
        \\//! @banjo[note-1] First line
        \\//! See @[other](note-2)
    ;

    const notes = try scanFileForNotes(alloc, content);
    defer {
        for (notes) |*n| @constCast(n).deinit(alloc);
        alloc.free(notes);
    }

    try testing.expectEqual(@as(usize, 1), notes.len);
    try testing.expectEqual(@as(usize, 1), notes[0].links.len);
    try testing.expectEqualStrings("note-2", notes[0].links[0]);
    try testing.expect(mem.indexOf(u8, notes[0].content, "See @[other](note-2)") != null);
}

test "getCommentPrefix returns correct prefix" {
    try testing.expectEqualStrings("//", getCommentPrefix("main.zig"));
    try testing.expectEqualStrings("//", getCommentPrefix("main.rs"));
    try testing.expectEqualStrings("#", getCommentPrefix("script.py"));
    try testing.expectEqualStrings("#", getCommentPrefix("config.yaml"));
    try testing.expectEqualStrings("--", getCommentPrefix("query.sql"));
}

test "formatNoteComment creates correct format" {
    const alloc = testing.allocator;
    const comment = try formatNoteComment(alloc, "note-123", "TODO fix this", "//");
    defer alloc.free(comment);

    try testing.expectEqualStrings("// @banjo[note-123] TODO fix this", comment);
}

test "generateNoteId returns 12 char hex string" {
    const id = generateNoteId();
    try testing.expectEqual(@as(usize, 12), id.len);
    // All chars should be hex
    for (id) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}
