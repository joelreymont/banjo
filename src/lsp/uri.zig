const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const UriPath = struct {
    path: []const u8,
    owned: bool,

    pub fn deinit(self: UriPath, allocator: Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

pub fn uriToPath(allocator: Allocator, uri: []const u8) !?UriPath {
    if (!mem.startsWith(u8, uri, "file://")) return null;
    const path_start = "file://".len;
    const hash_idx = mem.indexOfScalar(u8, uri, '#') orelse uri.len;
    if (hash_idx < path_start) return null;
    const raw_path = uri[path_start..hash_idx];
    if (raw_path.len == 0) return null;

    if (mem.indexOfScalar(u8, raw_path, '%') == null) {
        return .{ .path = raw_path, .owned = false };
    }

    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var i: usize = 0;
    while (i < raw_path.len) {
        if (raw_path[i] == '%' and i + 2 < raw_path.len) {
            const hex = raw_path[i + 1 .. i + 3];
            if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                try decoded.append(allocator, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try decoded.append(allocator, raw_path[i]);
        i += 1;
    }

    return .{ .path = try decoded.toOwnedSlice(allocator), .owned = true };
}

pub fn pathToUri(allocator: Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "file://");

    const hex = "0123456789ABCDEF";
    for (path) |byte| {
        if (isPathSafe(byte)) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0F]);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn isPathSafe(byte: u8) bool {
    return isUnreserved(byte) or byte == '/' or byte == ':';
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        byte == '-' or
        byte == '.' or
        byte == '_' or
        byte == '~';
}

// Tests
const testing = std.testing;
const quickcheck = @import("../util/quickcheck.zig");

test "uriToPath decodes percent sequences" {
    const uri = "file:///tmp/space%20here.txt";
    const parsed = try uriToPath(testing.allocator, uri) orelse return error.TestUnexpectedResult;
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("/tmp/space here.txt", parsed.path);
}

test "pathToUri encodes spaces" {
    const uri = try pathToUri(testing.allocator, "/tmp/space here.txt");
    defer testing.allocator.free(uri);

    try testing.expectEqualStrings("file:///tmp/space%20here.txt", uri);
}

test "pathToUri and uriToPath roundtrip" {
    try quickcheck.check(struct {
        fn property(args: struct { bytes: [16]u8 }) bool {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            const path = args.bytes[0..];
            const uri = pathToUri(arena.allocator(), path) catch return false;
            const parsed = uriToPath(arena.allocator(), uri) catch return false;
            if (parsed) |p| {
                return mem.eql(u8, p.path, path);
            }
            return false;
        }
    }.property, .{});
}
