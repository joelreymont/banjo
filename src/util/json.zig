const std = @import("std");
const Allocator = std.mem.Allocator;

/// Serialize any JSON-compatible value to an owned slice.
/// Caller owns the returned memory and must free with the same allocator.
pub fn serializeToJson(allocator: Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return out.toOwnedSlice();
}
