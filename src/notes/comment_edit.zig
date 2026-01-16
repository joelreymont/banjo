const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const LineIndex = struct {
    starts: std.ArrayListUnmanaged(usize) = .empty,

    pub fn init(allocator: Allocator, content: []const u8) !LineIndex {
        var starts: std.ArrayListUnmanaged(usize) = .empty;
        if (content.len == 0) return .{ .starts = starts };
        try starts.append(allocator, 0);
        for (content, 0..) |c, i| {
            if (c == '\n' and i + 1 < content.len) {
                try starts.append(allocator, i + 1);
            }
        }
        return .{ .starts = starts };
    }

    pub fn deinit(self: *LineIndex, allocator: Allocator) void {
        self.starts.deinit(allocator);
    }

    pub fn lineSlice(self: *const LineIndex, content: []const u8, line: u32) ?[]const u8 {
        const idx = std.math.cast(usize, line) orelse return null;
        if (idx >= self.starts.items.len) return null;
        const start = self.starts.items[idx];
        const end = if (idx + 1 < self.starts.items.len)
            self.starts.items[idx + 1] - 1
        else if (content.len > 0 and content[content.len - 1] == '\n')
            content.len - 1
        else
            content.len;
        return content[start..end];
    }
};

pub fn getLineContent(line_index: *const LineIndex, content: []const u8, line: u32) ?[]const u8 {
    return line_index.lineSlice(content, line);
}

pub fn getIndent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ' and c != '\t') {
            return line[0..i];
        }
    }
    return line;
}

const CommentPrefixKind = enum {
    slash,
    hash,
    dash,
    semi,
    html,
};

const CommentPrefix = struct {
    kind: CommentPrefixKind,
    len: usize,
};

const comment_prefixes = [_]struct {
    prefix: []const u8,
    kind: CommentPrefixKind,
}{
    .{ .prefix = "<!--", .kind = .html },
    .{ .prefix = "//", .kind = .slash },
    .{ .prefix = "--", .kind = .dash },
    .{ .prefix = "#", .kind = .hash },
    .{ .prefix = ";", .kind = .semi },
};

fn getCommentPrefix(trimmed: []const u8) ?CommentPrefix {
    for (comment_prefixes) |entry| {
        if (mem.startsWith(u8, trimmed, entry.prefix)) {
            return .{ .kind = entry.kind, .len = entry.prefix.len };
        }
    }
    return null;
}

pub fn isCommentLine(line_index: *const LineIndex, content: []const u8, line: u32) bool {
    const line_content = getLineContent(line_index, content, line) orelse return false;
    const trimmed = mem.trimLeft(u8, line_content, " \t");
    if (getCommentPrefix(trimmed) != null) {
        return mem.indexOf(u8, trimmed, "@banjo[") == null;
    }
    return false;
}

pub fn isCommentBlockLine(line_index: *const LineIndex, content: []const u8, line: u32) bool {
    const line_content = getLineContent(line_index, content, line) orelse return false;
    const trimmed = mem.trimLeft(u8, line_content, " \t");
    return getCommentPrefix(trimmed) != null;
}

fn castU32(value: usize) ?u32 {
    return std.math.cast(u32, value);
}

pub fn findCommentInsertOffset(line_content: []const u8) ?u32 {
    const trimmed = mem.trimLeft(u8, line_content, " \t");
    if (trimmed.len == 0) return null;

    const leading_spaces = line_content.len - trimmed.len;
    const prefix = getCommentPrefix(trimmed) orelse return null;

    var pos = prefix.len;
    switch (prefix.kind) {
        .slash => {
            while (pos < trimmed.len and (trimmed[pos] == '/' or trimmed[pos] == '!')) {
                pos += 1;
            }
        },
        .dash => {
            while (pos < trimmed.len and trimmed[pos] == '-') {
                pos += 1;
            }
        },
        .hash => {
            while (pos < trimmed.len and trimmed[pos] == '#') {
                pos += 1;
            }
        },
        .semi, .html => {},
    }
    while (pos < trimmed.len and (trimmed[pos] == ' ' or trimmed[pos] == '\t')) {
        pos += 1;
    }

    return castU32(leading_spaces + pos);
}

pub fn findCommentBlockStart(line_index: *const LineIndex, content: []const u8, line: u32) u32 {
    var current = line;
    while (current > 0) {
        const prev = current - 1;
        if (!isCommentBlockLine(line_index, content, prev)) break;
        current = prev;
    }
    return current;
}

pub fn findCommentBlockEnd(line_index: *const LineIndex, content: []const u8, line: u32) u32 {
    var current = line;
    while (true) {
        const next = current + 1;
        if (getLineContent(line_index, content, next) == null) break;
        if (!isCommentBlockLine(line_index, content, next)) break;
        current = next;
    }
    return current;
}

pub fn commentBlockHasNote(line_index: *const LineIndex, content: []const u8, start_line: u32, end_line: u32) bool {
    var line = start_line;
    while (line <= end_line) : (line += 1) {
        const line_content = getLineContent(line_index, content, line) orelse continue;
        if (mem.indexOf(u8, line_content, "@banjo[") != null) return true;
    }
    return false;
}

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "LineIndex init and lineSlice" {
    const content = "line1\nline2\nline3";
    var idx = try LineIndex.init(testing.allocator, content);
    defer idx.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), idx.starts.items.len);
    try testing.expectEqualStrings("line1", idx.lineSlice(content, 0).?);
    try testing.expectEqualStrings("line2", idx.lineSlice(content, 1).?);
    try testing.expectEqualStrings("line3", idx.lineSlice(content, 2).?);
    try testing.expect(idx.lineSlice(content, 3) == null);
}

test "getIndent extracts leading whitespace" {
    try testing.expectEqualStrings("", getIndent("no indent"));
    try testing.expectEqualStrings("  ", getIndent("  two spaces"));
    try testing.expectEqualStrings("\t", getIndent("\ttab"));
    try testing.expectEqualStrings("    ", getIndent("    four spaces"));
}

test "isCommentLine detects comment lines" {
    const content = "// comment\ncode\n# hash comment";
    var idx = try LineIndex.init(testing.allocator, content);
    defer idx.deinit(testing.allocator);

    const summary = .{
        .slash = isCommentLine(&idx, content, 0),
        .code = isCommentLine(&idx, content, 1),
        .hash = isCommentLine(&idx, content, 2),
    };
    try (ohsnap{}).snap(@src(),
        \\notes.comment_edit.test.isCommentLine detects comment lines__struct_<^\d+$>
        \\  .slash: bool = true
        \\  .code: bool = false
        \\  .hash: bool = true
    ).expectEqual(summary);
}

test "findCommentInsertOffset finds position after prefix" {
    try testing.expectEqual(@as(?u32, 3), findCommentInsertOffset("// comment"));
    try testing.expectEqual(@as(?u32, 4), findCommentInsertOffset("  # comment"));
    try testing.expect(findCommentInsertOffset("not a comment") == null);
    try testing.expect(findCommentInsertOffset("") == null);
}

test "findCommentBlockStart finds block start" {
    const content = "code\n// comment1\n// comment2\nmore code";
    var idx = try LineIndex.init(testing.allocator, content);
    defer idx.deinit(testing.allocator);

    // Line 2 is middle of comment block, should find start at line 1
    const start = findCommentBlockStart(&idx, content, 2);
    try testing.expectEqual(@as(u32, 1), start);
}

test "findCommentBlockEnd finds block end" {
    const content = "// comment1\n// comment2\n// comment3\ncode";
    var idx = try LineIndex.init(testing.allocator, content);
    defer idx.deinit(testing.allocator);

    // Line 0 is start of comment block, should find end at line 2
    const end = findCommentBlockEnd(&idx, content, 0);
    try testing.expectEqual(@as(u32, 2), end);
}
