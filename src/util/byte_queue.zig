const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ByteQueue = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    pos: usize = 0,

    pub fn deinit(self: *ByteQueue, allocator: Allocator) void {
        self.buf.deinit(allocator);
        self.pos = 0;
    }

    pub fn clear(self: *ByteQueue) void {
        self.buf.items.len = 0;
        self.pos = 0;
    }

    pub fn len(self: *const ByteQueue) usize {
        if (self.pos >= self.buf.items.len) return 0;
        return self.buf.items.len - self.pos;
    }

    pub fn slice(self: *const ByteQueue) []const u8 {
        if (self.pos >= self.buf.items.len) {
            return self.buf.items[self.buf.items.len..];
        }
        return self.buf.items[self.pos..];
    }

    pub fn append(self: *ByteQueue, allocator: Allocator, data: []const u8) !void {
        if (data.len == 0) return;
        if (self.pos > 0) {
            const need = self.buf.items.len + data.len;
            if (need > self.buf.capacity or self.pos >= min_compact and self.pos >= self.buf.items.len / 2) {
                self.compact();
            }
        }
        try self.buf.appendSlice(allocator, data);
    }

    pub fn consume(self: *ByteQueue, n: usize) void {
        if (n >= self.len()) {
            self.clear();
            return;
        }
        self.pos += n;
    }

    fn compact(self: *ByteQueue) void {
        if (self.pos == 0) return;
        if (self.pos >= self.buf.items.len) {
            self.clear();
            return;
        }
        const remaining = self.buf.items[self.pos..];
        std.mem.copyForwards(u8, self.buf.items[0..remaining.len], remaining);
        self.buf.items.len = remaining.len;
        self.pos = 0;
    }
};

const min_compact: usize = 4096;

const testing = std.testing;

test "ByteQueue append and consume preserve order" {
    var q = ByteQueue{};
    defer q.deinit(testing.allocator);

    try q.append(testing.allocator, "hello");
    try testing.expectEqual(@as(usize, 5), q.len());
    try testing.expect(std.mem.eql(u8, q.slice(), "hello"));

    q.consume(2);
    try testing.expectEqual(@as(usize, 3), q.len());
    try testing.expect(std.mem.eql(u8, q.slice(), "llo"));

    try q.append(testing.allocator, "!!");
    try testing.expectEqual(@as(usize, 5), q.len());
    try testing.expect(std.mem.eql(u8, q.slice(), "llo!!"));

    q.consume(5);
    try testing.expectEqual(@as(usize, 0), q.len());
}
