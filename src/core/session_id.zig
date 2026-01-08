const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

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
