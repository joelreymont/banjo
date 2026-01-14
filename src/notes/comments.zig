const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.comments);

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
    const real_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(real_path);
    if (!std.mem.eql(u8, real_path, file_path)) return error.PathChanged;

    const file = try std.fs.openFileAbsolute(real_path, .{ .mode = .read_only });
    defer file.close();

    // Atomic write: write to temp file with random suffix, then rename
    var random_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.banjo.{x:0>8}.tmp", .{
        file_path,
        std.mem.readInt(u32, &random_bytes, .little),
    });
    defer allocator.free(tmp_path);

    const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{});
    var tmp_closed = false;
    defer if (!tmp_closed) tmp_file.close();
    errdefer {
        std.fs.deleteFileAbsolute(tmp_path) catch |cleanup_err| {
            log.warn("Failed to remove temp file {s}: {}", .{ tmp_path, cleanup_err });
        };
    }

    var line: u32 = 1;
    var at_line_start = true;
    var inserted = false;

    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var reader = file.reader(&reader_buf);
    const r = &reader.interface;
    var writer = tmp_file.writer(&writer_buf);
    const w = &writer.interface;

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&buf);
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) {
            if (!inserted and at_line_start and line == line_num) {
                try w.writeAll(text);
                inserted = true;
            }
            if (std.mem.indexOfScalarPos(u8, buf[0..n], i, '\n')) |nl| {
                try w.writeAll(buf[i .. nl + 1]);
                line += 1;
                at_line_start = true;
                i = nl + 1;
            } else {
                try w.writeAll(buf[i..n]);
                at_line_start = false;
                i = n;
            }
        }
    }

    if (!inserted) {
        if ((line == line_num and at_line_start) or line + 1 == line_num) {
            try w.writeAll(text);
            inserted = true;
        } else {
            return error.LineOutOfBounds;
        }
    }

    try w.flush();
    tmp_file.close();
    tmp_closed = true;

    // Atomic rename
    std.fs.renameAbsolute(tmp_path, file_path) catch |err| {
        std.fs.deleteFileAbsolute(tmp_path) catch |cleanup_err| {
            log.warn("Failed to remove temp file {s}: {}", .{ tmp_path, cleanup_err });
        };
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
const ohsnap = @import("ohsnap");

test "parseNoteLine extracts note ID and content" {
    const alloc = testing.allocator;
    var note = (try parseNoteLine(alloc, "// @banjo[note-123] TODO fix this", 5)).?;
    defer note.deinit(alloc);
    const summary = .{
        .id = note.id,
        .content = note.content,
        .line = note.line,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.parseNoteLine extracts note ID and content__struct_<^\d+$>
        \\  .id: []const u8
        \\    "note-123"
        \\  .content: []const u8
        \\    "TODO fix this"
        \\  .line: u32 = 5
    ).expectEqual(summary);
}

test "parseNoteLine returns null for non-note lines" {
    const alloc = testing.allocator;
    const summary = .{
        .comment = (try parseNoteLine(alloc, "// regular comment", 1)) == null,
        .code = (try parseNoteLine(alloc, "const x = 5;", 1)) == null,
        .empty = (try parseNoteLine(alloc, "", 1)) == null,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.parseNoteLine returns null for non-note lines__struct_<^\d+$>
        \\  .comment: bool = true
        \\  .code: bool = true
        \\  .empty: bool = true
    ).expectEqual(summary);
}

test "parseNoteLine handles different comment styles" {
    const alloc = testing.allocator;

    var note1 = (try parseNoteLine(alloc, "# @banjo[py-note] Python note", 1)).?;
    defer note1.deinit(alloc);
    var note2 = (try parseNoteLine(alloc, "-- @banjo[sql-note] SQL note", 1)).?;
    defer note2.deinit(alloc);
    const summary = .{
        .py = note1.id,
        .sql = note2.id,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.parseNoteLine handles different comment styles__struct_<^\d+$>
        \\  .py: []const u8
        \\    "py-note"
        \\  .sql: []const u8
        \\    "sql-note"
    ).expectEqual(summary);
}

test "parseNoteLine extracts links" {
    const alloc = testing.allocator;
    var note = (try parseNoteLine(alloc, "// @banjo[note-1] See @[other note](note-2) and @[third](note-3)", 1)).?;
    defer note.deinit(alloc);
    const summary = .{
        .links = note.links,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.parseNoteLine extracts links__struct_<^\d+$>
        \\  .links: []const []const u8
        \\    [0]: []const u8
        \\      "note-2"
        \\    [1]: []const u8
        \\      "note-3"
    ).expectEqual(summary);
}

test "insertAtLine inserts into middle and appends" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const file_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "note.txt" });
    defer testing.allocator.free(file_path);

    {
        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();
        try file.writeAll("one\ntwo\nthree");
    }
    try insertAtLine(testing.allocator, file_path, 2, "INS\n");
    {
        const file = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        defer file.close();
        const content = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(content);
        const expected = "one\nINS\ntwo\nthree";
        try (ohsnap{}).snap(@src(), expected).diff(content, true);
    }

    {
        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();
        try file.writeAll("one\ntwo\n");
    }
    try insertAtLine(testing.allocator, file_path, 3, "INS\n");
    {
        const file = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        defer file.close();
        const content = try file.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(content);
        const expected = "one\ntwo\nINS\n";
        try (ohsnap{}).snap(@src(), expected).diff(content, true);
    }
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

    const summary = .{
        .count = notes.len,
        .first = .{ .id = notes[0].id, .line = notes[0].line },
        .second = .{ .id = notes[1].id, .line = notes[1].line },
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.scanFileForNotes finds all notes__struct_<^\d+$>
        \\  .count: usize = 2
        \\  .first: notes.comments.test.scanFileForNotes finds all notes__struct_<^\d+$>
        \\    .id: []const u8
        \\      "note-1"
        \\    .line: u32 = 2
        \\  .second: notes.comments.test.scanFileForNotes finds all notes__struct_<^\d+$>
        \\    .id: []const u8
        \\      "note-2"
        \\    .line: u32 = 4
    ).expectEqual(summary);
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

    const summary = .{
        .count = notes.len,
        .links = notes[0].links,
        .content = notes[0].content,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.scanFileForNotes captures links in comment blocks__struct_<^\d+$>
        \\  .count: usize = 1
        \\  .links: []const []const u8
        \\    [0]: []const u8
        \\      "note-2"
        \\  .content: []const u8
        \\    "First line
        \\See @[other](note-2)"
    ).expectEqual(summary);
}

test "getCommentPrefix returns correct prefix" {
    const summary = .{
        .zig = getCommentPrefix("main.zig"),
        .rs = getCommentPrefix("main.rs"),
        .py = getCommentPrefix("script.py"),
        .yaml = getCommentPrefix("config.yaml"),
        .sql = getCommentPrefix("query.sql"),
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.getCommentPrefix returns correct prefix__struct_<^\d+$>
        \\  .zig: []const u8
        \\    "//"
        \\  .rs: []const u8
        \\    "//"
        \\  .py: []const u8
        \\    "#"
        \\  .yaml: []const u8
        \\    "#"
        \\  .sql: []const u8
        \\    "--"
    ).expectEqual(summary);
}

test "formatNoteComment creates correct format" {
    const alloc = testing.allocator;
    const comment = try formatNoteComment(alloc, "note-123", "TODO fix this", "//");
    defer alloc.free(comment);
    const summary = .{ .comment = comment };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.formatNoteComment creates correct format__struct_<^\d+$>
        \\  .comment: []const u8
        \\    "// @banjo[note-123] TODO fix this"
    ).expectEqual(summary);
}

test "generateNoteId returns 12 char hex string" {
    const id = generateNoteId();
    var all_hex = true;
    for (id) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
            all_hex = false;
            break;
        }
    }
    const summary = .{ .len = id.len, .all_hex = all_hex };
    try (ohsnap{}).snap(@src(),
        \\notes.comments.test.generateNoteId returns 12 char hex string__struct_<^\d+$>
        \\  .len: usize = 12
        \\  .all_hex: bool = true
    ).expectEqual(summary);
}

//
// Property tests
//

const zcheck = @import("zcheck");
const zcheck_seed_base: u64 = 0x9e07_3b1d_c54a_82f1;

const Bytes64 = zcheck.BoundedSlice(u8, 64);
const Bytes48 = zcheck.BoundedSlice(u8, 48);
const Bytes32 = zcheck.BoundedSlice(u8, 32);

fn checkWithResult(prop: anytype, config: zcheck.Config, label: []const u8) !void {
    if (try zcheck.checkResult(prop, config)) |failure| {
        std.debug.print(
            "zcheck failure: {s}\nseed: {}\noriginal: {any}\nshrunk: {any}\n",
            .{ label, failure.seed, failure.original, failure.shrunk },
        );
        return error.TestUnexpectedResult;
    }
}

test "lexer never crashes on arbitrary bytes" {
    try zcheck.check(struct {
        fn prop(args: struct { bytes: Bytes64 }) bool {
            const bytes = args.bytes.slice();
            var lexer = Lexer.init(bytes);
            // Consume all tokens - should never crash
            while (true) {
                const tok = lexer.next();
                if (tok.tag == .eof or tok.tag == .not_comment) break;
                // Bounds check
                if (tok.end > bytes.len) return false;
                if (tok.start > tok.end) return false;
            }
            return true;
        }
    }.prop, .{ .iterations = 1000, .seed = zcheck_seed_base + 1 });
}

test "lexer terminates on any input" {
    try zcheck.check(struct {
        fn prop(args: struct { bytes: Bytes32 }) bool {
            const bytes = args.bytes.slice();
            var lexer = Lexer.init(bytes);
            var count: usize = 0;
            while (count < 1000) : (count += 1) {
                const tok = lexer.next();
                if (tok.tag == .eof or tok.tag == .not_comment) return true;
            }
            return false; // Didn't terminate
        }
    }.prop, .{ .iterations = 500, .seed = zcheck_seed_base + 2 });
}

test "round-trip: formatNoteComment then parseNoteLine" {
    try checkWithResult(struct {
        fn prop(args: struct { id: zcheck.Id, content: zcheck.String }) !bool {
            const id = args.id.slice();
            const raw_content = args.content.slice();
            var filtered: [zcheck.String.MAX_LEN]u8 = undefined;
            var len: usize = 0;
            for (raw_content) |c| {
                if (std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '_') {
                    filtered[len] = c;
                    len += 1;
                }
            }
            const filtered_content = if (len == 0) "note" else filtered[0..len];
            const trimmed = std.mem.trim(u8, filtered_content, " \t");
            const content = if (trimmed.len == 0) "note" else trimmed;

            // Format and parse
            var buf: [160]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&buf, "// @banjo[{s}] {s}", .{ id, content });

            const alloc = testing.allocator;
            var note = try parseNoteLine(alloc, formatted, 1);
            if (note) |*n| {
                defer n.deinit(alloc);
                // ID should match
                if (!mem.eql(u8, n.id, id)) return false;
                // Content should contain our text
                if (mem.indexOf(u8, n.content, content) == null) return false;
            } else {
                return false; // Should have parsed
            }
            return true;
        }
    }.prop, .{ .iterations = 200, .seed = zcheck_seed_base + 3 }, "note roundtrip");
}

test "lexer slice bounds are always valid" {
    try zcheck.check(struct {
        fn prop(args: struct { bytes: Bytes48 }) bool {
            const bytes = args.bytes.slice();
            var lexer = Lexer.init(bytes);
            while (true) {
                const tok = lexer.next();
                switch (tok.tag) {
                    .eof, .not_comment => break,
                    .content, .banjo_marker, .link => {
                        // Verify slice is safe
                        if (tok.start > tok.end) return false;
                        if (tok.end > bytes.len) return false;
                        _ = lexer.slice(tok); // Should not panic
                    },
                }
            }
            return true;
        }
    }.prop, .{ .iterations = 500, .seed = zcheck_seed_base + 4 });
}
