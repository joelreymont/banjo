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

const testing = std.testing;
const ohsnap = @import("ohsnap");

test "serializeToJson roundtrip" {
    const original = .{
        .name = "banjo",
        .count = @as(u32, 3),
        .ok = true,
    };
    const json = try serializeToJson(testing.allocator, original);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const summary = .{
        .has_name = parsed.value.object.get("name") != null,
        .has_count = parsed.value.object.get("count") != null,
        .has_ok = parsed.value.object.get("ok") != null,
    };
    try (ohsnap{}).snap(@src(),
        \\util.json.test.serializeToJson roundtrip__struct_<^\d+$>
        \\  .has_name: bool = true
        \\  .has_count: bool = true
        \\  .has_ok: bool = true
    ).expectEqual(summary);
}

test "serializeToJson unicode" {
    const original = .{
        .text = "naïve café ☕",
    };
    const json = try serializeToJson(testing.allocator, original);
    defer testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const value = parsed.value.object.get("text").?;
    try testing.expectEqualStrings("naïve café ☕", value.string);
}
