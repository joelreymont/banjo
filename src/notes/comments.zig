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

/// Token types produced by the comment lexer
pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        /// Comment content (after prefix stripped)
        content,
        /// @banjo[id] marker - slice is the ID
        banjo_marker,
        /// @[display](target) link - slice is the target ID
        link,
        /// End of input
        eof,
        /// Line is not a comment
        not_comment,
    };
};

/// Single-pass lexer for comment lines using labeled switch state machine
pub const Lexer = struct {
    buffer: []const u8,
    index: usize = 0,
    content_start: usize = 0,

    const State = enum {
        start,
        slash,
        slash_slash,
        hash,
        dash,
        dash_dash,
        semicolon,
        angle_open,
        angle_excl,
        angle_excl_dash,
        angle_excl_dash_dash,
        comment_content,
        at_sign,
        banjo_b,
        banjo_a,
        banjo_n,
        banjo_j,
        banjo_o,
        banjo_id,
        link_display,
        link_paren,
        link_target,
        html_end_dash1,
        html_end_dash2,
    };

    pub fn init(buffer: []const u8) Lexer {
        return .{ .buffer = buffer };
    }

    pub fn next(self: *Lexer) Token {
        var result = Token{ .tag = .eof, .start = self.index, .end = self.index };
        var state: State = .start;
        var html_comment = false;

        state: while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    ' ', '\t' => continue :state,
                    '/' => state = .slash,
                    '#' => state = .hash,
                    '-' => state = .dash,
                    ';' => state = .semicolon,
                    '<' => state = .angle_open,
                    else => {
                        result.tag = .not_comment;
                        return result;
                    },
                },

                .slash => switch (c) {
                    '/' => state = .slash_slash,
                    else => {
                        result.tag = .not_comment;
                        return result;
                    },
                },

                .slash_slash => switch (c) {
                    '/', '!' => continue :state, // Skip /// or //!
                    ' ', '\t' => {
                        self.content_start = self.index + 1;
                        state = .comment_content;
                    },
                    '@' => {
                        self.content_start = self.index;
                        state = .at_sign;
                    },
                    else => {
                        self.content_start = self.index;
                        state = .comment_content;
                    },
                },

                .hash => switch (c) {
                    '#' => continue :state, // Skip ###
                    ' ', '\t' => {
                        self.content_start = self.index + 1;
                        state = .comment_content;
                    },
                    '@' => {
                        self.content_start = self.index;
                        state = .at_sign;
                    },
                    else => {
                        self.content_start = self.index;
                        state = .comment_content;
                    },
                },

                .dash => switch (c) {
                    '-' => state = .dash_dash,
                    else => {
                        result.tag = .not_comment;
                        return result;
                    },
                },

                .dash_dash => switch (c) {
                    '-' => continue :state, // Skip ---
                    ' ', '\t' => {
                        self.content_start = self.index + 1;
                        state = .comment_content;
                    },
                    '@' => {
                        self.content_start = self.index;
                        state = .at_sign;
                    },
                    else => {
                        self.content_start = self.index;
                        state = .comment_content;
                    },
                },

                .semicolon => switch (c) {
                    ';' => continue :state, // Skip ;;;
                    ' ', '\t' => {
                        self.content_start = self.index + 1;
                        state = .comment_content;
                    },
                    '@' => {
                        self.content_start = self.index;
                        state = .at_sign;
                    },
                    else => {
                        self.content_start = self.index;
                        state = .comment_content;
                    },
                },

                .angle_open => switch (c) {
                    '!' => state = .angle_excl,
                    else => {
                        result.tag = .not_comment;
                        return result;
                    },
                },

                .angle_excl => switch (c) {
                    '-' => state = .angle_excl_dash,
                    else => {
                        result.tag = .not_comment;
                        return result;
                    },
                },

                .angle_excl_dash => switch (c) {
                    '-' => {
                        html_comment = true;
                        state = .angle_excl_dash_dash;
                    },
                    else => {
                        result.tag = .not_comment;
                        return result;
                    },
                },

                .angle_excl_dash_dash => switch (c) {
                    ' ', '\t' => {
                        self.content_start = self.index + 1;
                        state = .comment_content;
                    },
                    '@' => {
                        self.content_start = self.index;
                        state = .at_sign;
                    },
                    else => {
                        self.content_start = self.index;
                        state = .comment_content;
                    },
                },

                .comment_content => switch (c) {
                    '@' => state = .at_sign,
                    '-' => if (html_comment) {
                        state = .html_end_dash1;
                    },
                    else => continue :state,
                },

                .html_end_dash1 => switch (c) {
                    '-' => state = .html_end_dash2,
                    '@' => state = .at_sign,
                    else => state = .comment_content,
                },

                .html_end_dash2 => switch (c) {
                    '>' => {
                        // End of HTML comment, return content without -->
                        result.tag = .content;
                        result.start = self.content_start;
                        result.end = self.index - 2;
                        self.index += 1;
                        return result;
                    },
                    '-' => continue :state,
                    '@' => state = .at_sign,
                    else => state = .comment_content,
                },

                .at_sign => switch (c) {
                    'b' => state = .banjo_b,
                    '[' => {
                        result.start = self.index + 1;
                        state = .link_display;
                    },
                    else => state = .comment_content,
                },

                .banjo_b => switch (c) {
                    'a' => state = .banjo_a,
                    else => state = .comment_content,
                },

                .banjo_a => switch (c) {
                    'n' => state = .banjo_n,
                    else => state = .comment_content,
                },

                .banjo_n => switch (c) {
                    'j' => state = .banjo_j,
                    else => state = .comment_content,
                },

                .banjo_j => switch (c) {
                    'o' => state = .banjo_o,
                    else => state = .comment_content,
                },

                .banjo_o => switch (c) {
                    '[' => {
                        result.start = self.index + 1;
                        state = .banjo_id;
                    },
                    else => state = .comment_content,
                },

                .banjo_id => switch (c) {
                    ']' => {
                        result.tag = .banjo_marker;
                        result.end = self.index;
                        self.index += 1;
                        self.content_start = self.index;
                        return result;
                    },
                    else => continue :state,
                },

                .link_display => switch (c) {
                    ']' => state = .link_paren,
                    else => continue :state,
                },

                .link_paren => switch (c) {
                    '(' => {
                        result.start = self.index + 1;
                        state = .link_target;
                    },
                    else => state = .comment_content,
                },

                .link_target => switch (c) {
                    ')' => {
                        result.tag = .link;
                        result.end = self.index;
                        self.index += 1;
                        return result;
                    },
                    else => continue :state,
                },
            }
        }

        // End of buffer
        switch (state) {
            .comment_content, .html_end_dash1, .html_end_dash2 => {
                result.tag = .content;
                result.start = self.content_start;
                result.end = self.buffer.len;
            },
            .banjo_id, .link_display, .link_paren, .link_target => {
                // Incomplete token at end
                result.tag = .eof;
            },
            else => {
                result.tag = .eof;
            },
        }
        return result;
    }

    pub fn slice(self: *const Lexer, tok: Token) []const u8 {
        return self.buffer[tok.start..tok.end];
    }
};

const banjo_marker = "@banjo[";

/// Extract comment content from a line using the lexer.
/// Returns null if line is not a comment.
fn stripCommentPrefix(line: []const u8) ?[]const u8 {
    var lexer = Lexer.init(line);
    const tok = lexer.next();
    return switch (tok.tag) {
        .content => lexer.slice(tok),
        .banjo_marker => line[tok.end + 1 ..], // Everything after ]
        .link => line[lexer.content_start..],
        .not_comment, .eof => null,
    };
}

/// Scan content for @[display](target) links using simple string matching.
/// This is used for content that has already been stripped of comment prefixes.
fn parseLinksInto(allocator: Allocator, links: *std.ArrayListUnmanaged([]const u8), content: []const u8) !void {
    var pos: usize = 0;
    while (pos < content.len) {
        const link_start = mem.indexOfPos(u8, content, pos, link_prefix) orelse break;
        const mid = mem.indexOfPos(u8, content, link_start + link_prefix.len, "](") orelse {
            pos = link_start + link_prefix.len;
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

/// Parse a single line for a @banjo note comment using the lexer
/// Returns null if line doesn't contain a banjo note
pub fn parseNoteLine(allocator: Allocator, line: []const u8, line_number: u32) !?ParsedNote {
    var lexer = Lexer.init(line);
    var note_id: ?[]const u8 = null;
    var content_start_pos: usize = 0;

    // First pass: find @banjo marker
    while (true) {
        const tok = lexer.next();
        switch (tok.tag) {
            .banjo_marker => {
                if (tok.end > tok.start) {
                    note_id = lexer.slice(tok);
                    content_start_pos = lexer.content_start;
                }
            },
            .not_comment, .eof => break,
            .content, .link => continue,
        }
    }

    const id_slice = note_id orelse return null;
    const id = try allocator.dupe(u8, id_slice);
    errdefer allocator.free(id);

    // Content is everything after the note ID marker
    const content = if (content_start_pos < line.len) line[content_start_pos..] else "";
    const duped_content = try allocator.dupe(u8, mem.trim(u8, content, " \t"));
    errdefer allocator.free(duped_content);

    // Parse links from the content
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
    writeHexLower(buf[0..8], timestamp_low);
    writeHexLower(buf[8..12], random);
    return buf;
}

fn writeHexLower(buf: []u8, value: u64) void {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const shift: u6 = @intCast((buf.len - 1 - i) * 4);
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        buf[i] = hex[nibble];
    }
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
