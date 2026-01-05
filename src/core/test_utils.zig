const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn normalizeSnapshotText(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var last_space = false;
    for (input) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (out.items.len == 0 or last_space) continue;
            try out.append(allocator, ' ');
            last_space = true;
            continue;
        }
        last_space = false;
        try out.append(allocator, c);
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }

    return try out.toOwnedSlice(allocator);
}
