const std = @import("std");

pub const SummaryOptions = struct {
    max_len: usize,
    prefer_word_boundary: bool,
};

pub fn getSummary(text: []const u8, options: SummaryOptions) []const u8 {
    var end: usize = text.len;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            end = i;
            break;
        }
    }

    if (end <= options.max_len) return text[0..end];
    if (!options.prefer_word_boundary) return text[0..options.max_len];

    var split: usize = options.max_len;
    while (split > 0 and text[split] != ' ') : (split -= 1) {}
    return if (split > 0) text[0..split] else text[0..options.max_len];
}

// Tests
const testing = std.testing;

test "getSummary truncates at max_len" {
    const text = "hello world this is a long string";
    const result = getSummary(text, .{ .max_len = 10, .prefer_word_boundary = false });
    try testing.expectEqualStrings("hello worl", result);
}

test "getSummary stops at newline" {
    const text = "first line\nsecond line";
    const result = getSummary(text, .{ .max_len = 100, .prefer_word_boundary = false });
    try testing.expectEqualStrings("first line", result);
}

test "getSummary prefers word boundary" {
    const text = "hello world this is a long string";
    const result = getSummary(text, .{ .max_len = 10, .prefer_word_boundary = true });
    try testing.expectEqualStrings("hello", result);
}

test "getSummary short text unchanged" {
    const text = "short";
    const result = getSummary(text, .{ .max_len = 100, .prefer_word_boundary = true });
    try testing.expectEqualStrings("short", result);
}

test "getSummary no word boundary fallback" {
    const text = "superlongwordwithoutspaces";
    const result = getSummary(text, .{ .max_len = 10, .prefer_word_boundary = true });
    // Falls back to max_len since no space found
    try testing.expectEqualStrings("superlongw", result);
}
