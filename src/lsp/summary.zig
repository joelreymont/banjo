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
