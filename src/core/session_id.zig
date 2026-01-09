const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const test_env = @import("../util/test_env.zig");

pub fn generate(allocator: Allocator, prefix: ?[]const u8) ![]const u8 {
    if (builtin.is_test) {
        if (std.posix.getenv("BANJO_TEST_SESSION_ID")) |sid| {
            if (prefix) |p| {
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ p, sid });
            }
            return allocator.dupe(u8, sid);
        }
    }

    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    const hex_slice: []const u8 = &hex;
    if (prefix) |p| {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ p, hex_slice });
    }
    return allocator.dupe(u8, hex_slice);
}

test "generate uses test session id override" {
    const testing = std.testing;
    const ohsnap = @import("ohsnap");
    var guard = try test_env.EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", "fixed");
    defer guard.deinit();

    const id = try generate(testing.allocator, null);
    defer testing.allocator.free(id);

    const prefixed = try generate(testing.allocator, "sess_");
    defer testing.allocator.free(prefixed);
    const summary = .{
        .id = id,
        .prefixed = prefixed,
    };
    try (ohsnap{}).snap(@src(),
        \\core.session_id.test.generate uses test session id override__struct_<^\d+$>
        \\  .id: []const u8
        \\    "fixed"
        \\  .prefixed: []const u8
        \\    "sess_fixed"
    ).expectEqual(summary);
}

test "generate creates lowercase hex ids" {
    const testing = std.testing;
    const ohsnap = @import("ohsnap");
    var guard = try test_env.EnvVarGuard.set(testing.allocator, "BANJO_TEST_SESSION_ID", null);
    defer guard.deinit();

    const prefix = "sess_";
    const id = try generate(testing.allocator, prefix);
    defer testing.allocator.free(id);

    const hex = id[prefix.len..];
    var all_hex = true;
    var all_lower = true;
    for (hex) |ch| {
        if (!std.ascii.isHex(ch)) all_hex = false;
        if (std.ascii.isUpper(ch)) all_lower = false;
    }
    const summary = .{
        .len = id.len,
        .prefix = id[0..prefix.len],
        .all_hex = all_hex,
        .all_lower = all_lower,
    };
    try (ohsnap{}).snap(@src(),
        \\core.session_id.test.generate creates lowercase hex ids__struct_<^\d+$>
        \\  .len: usize = 37
        \\  .prefix: *const [5]u8
        \\    [0]: u8 = 115
        \\    [1]: u8 = 101
        \\    [2]: u8 = 115
        \\    [3]: u8 = 115
        \\    [4]: u8 = 95
        \\  .all_hex: bool = true
        \\  .all_lower: bool = true
    ).expectEqual(summary);
}
