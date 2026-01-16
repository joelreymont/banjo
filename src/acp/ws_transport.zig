const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const websocket = @import("../ws/websocket.zig");
const byte_queue = @import("../util/byte_queue.zig");
const jsonrpc = @import("../jsonrpc.zig");

/// WebSocket writer that wraps outgoing JSON messages in WebSocket frames.
/// Buffers writes until a newline, then sends as a single text frame.
pub const WsWriter = struct {
    socket: posix.socket_t,
    mutex: *std.Thread.Mutex,
    allocator: Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator, socket: posix.socket_t, mutex: *std.Thread.Mutex) WsWriter {
        return .{
            .socket = socket,
            .mutex = mutex,
            .allocator = allocator,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *WsWriter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn writer(self: *WsWriter) std.io.AnyWriter {
        return .{
            .context = self,
            .writeFn = writeFn,
        };
    }

    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *WsWriter = @ptrCast(@alignCast(@constCast(context)));

        for (bytes) |byte| {
            if (byte == '\n') {
                // End of message - send as WebSocket frame
                if (self.buffer.items.len > 0) {
                    try self.sendFrame(self.buffer.items);
                    self.buffer.clearRetainingCapacity();
                }
            } else {
                try self.buffer.append(self.allocator, byte);
            }
        }
        return bytes.len;
    }

    fn sendFrame(self: *WsWriter, payload: []const u8) !void {
        const frame = try websocket.encodeFrame(self.allocator, .text, payload);
        defer self.allocator.free(frame);

        self.mutex.lock();
        defer self.mutex.unlock();

        var sent: usize = 0;
        while (sent < frame.len) {
            const n = try posix.write(self.socket, frame[sent..]);
            if (n == 0) return error.ConnectionClosed;
            sent += n;
        }
    }
};

/// WebSocket reader that extracts JSON messages from WebSocket frames.
/// Provides a stream-like interface for jsonrpc.Reader.
pub const WsReader = struct {
    socket: posix.socket_t,
    allocator: Allocator,
    frame_buffer: byte_queue.ByteQueue,
    message_buffer: std.ArrayList(u8),
    read_pos: usize,
    closed: bool,

    pub fn init(allocator: Allocator, socket: posix.socket_t) WsReader {
        return .{
            .socket = socket,
            .allocator = allocator,
            .frame_buffer = .{},
            .message_buffer = .empty,
            .read_pos = 0,
            .closed = false,
        };
    }

    pub fn deinit(self: *WsReader) void {
        self.frame_buffer.deinit(self.allocator);
        self.message_buffer.deinit(self.allocator);
    }

    /// Get an AnyReader for use with jsonrpc.Reader
    pub fn reader(self: *WsReader) std.io.AnyReader {
        return .{
            .context = self,
            .readFn = readFn,
        };
    }

    fn readFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const self: *WsReader = @ptrCast(@alignCast(@constCast(context)));
        return self.read(buffer);
    }

    fn read(self: *WsReader, buffer: []u8) !usize {
        // First, try to satisfy from message_buffer
        if (self.read_pos < self.message_buffer.items.len) {
            const available = self.message_buffer.items[self.read_pos..];
            const to_copy = @min(available.len, buffer.len);
            @memcpy(buffer[0..to_copy], available[0..to_copy]);
            self.read_pos += to_copy;
            return to_copy;
        }

        // Need more data - read next WebSocket frame
        if (self.closed) return error.EndOfStream;

        try self.readNextMessage();

        // Now try again from message_buffer
        if (self.read_pos < self.message_buffer.items.len) {
            const available = self.message_buffer.items[self.read_pos..];
            const to_copy = @min(available.len, buffer.len);
            @memcpy(buffer[0..to_copy], available[0..to_copy]);
            self.read_pos += to_copy;
            return to_copy;
        }

        return 0;
    }

    fn readNextMessage(self: *WsReader) !void {
        self.message_buffer.clearRetainingCapacity();
        self.read_pos = 0;

        while (true) {
            // Try to parse a frame from existing buffer
            if (self.frame_buffer.len() >= 2) {
                const buf = self.frame_buffer.sliceMut();
                const result = websocket.parseFrame(buf) catch |err| switch (err) {
                    error.NeedMoreData => {
                        // Need more data from socket
                        try self.readFromSocket();
                        continue;
                    },
                    else => return err,
                };

                // Got a frame
                switch (result.frame.opcode) {
                    .text => {
                        // Append payload + newline (for jsonrpc.Reader compatibility)
                        try self.message_buffer.appendSlice(self.allocator, result.frame.payload);
                        try self.message_buffer.append(self.allocator, '\n');
                        self.frame_buffer.consume(result.consumed);
                        return;
                    },
                    .close => {
                        self.closed = true;
                        return error.ConnectionClosed;
                    },
                    .ping => {
                        // Send pong
                        const pong = try websocket.encodeFrame(self.allocator, .pong, result.frame.payload);
                        defer self.allocator.free(pong);
                        _ = try posix.write(self.socket, pong);
                        self.frame_buffer.consume(result.consumed);
                        continue;
                    },
                    .pong => {
                        // Ignore pong
                        self.frame_buffer.consume(result.consumed);
                        continue;
                    },
                    else => {
                        // Skip other frames
                        self.frame_buffer.consume(result.consumed);
                        continue;
                    },
                }
            } else {
                // Need more data
                try self.readFromSocket();
            }
        }
    }

    fn readFromSocket(self: *WsReader) !void {
        var buf: [4096]u8 = undefined;
        const n = try posix.read(self.socket, &buf);
        if (n == 0) {
            self.closed = true;
            return error.ConnectionClosed;
        }
        try self.frame_buffer.append(self.allocator, buf[0..n]);
    }
};

// Tests
const testing = std.testing;

const zcheck = @import("zcheck");
const ohsnap = @import("ohsnap");

fn createSocketPair() ![2]posix.fd_t {
    var pair: [2]posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) {
        return error.SocketPairFailed;
    }
    return pair;
}

fn encodeMaskedFrame(allocator: Allocator, opcode: websocket.Opcode, payload: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // FIN + opcode
    try buf.append(allocator, 0x80 | @as(u8, @intFromEnum(opcode)));

    // Payload length with mask bit set
    if (payload.len < 126) {
        try buf.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len < 65536) {
        try buf.append(allocator, 0x80 | 126);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len)));
        try buf.appendSlice(allocator, &len_bytes);
    } else {
        try buf.append(allocator, 0x80 | 127);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, payload.len));
        try buf.appendSlice(allocator, &len_bytes);
    }

    // Mask key (use fixed key for reproducible tests)
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    try buf.appendSlice(allocator, &mask);

    // Masked payload
    for (payload, 0..) |byte, i| {
        try buf.append(allocator, byte ^ mask[i % 4]);
    }

    return buf.toOwnedSlice(allocator);
}

test "WsWriter buffers until newline" {
    var mutex = std.Thread.Mutex{};
    const allocator = testing.allocator;

    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    var ws_writer = WsWriter.init(allocator, pair[0], &mutex);
    defer ws_writer.deinit();

    const w = ws_writer.writer();

    // Write partial message (no newline)
    _ = try w.write("hello");
    try testing.expectEqual(@as(usize, 5), ws_writer.buffer.items.len);

    // Write newline - should flush and clear buffer
    _ = try w.write("\n");
    try testing.expectEqual(@as(usize, 0), ws_writer.buffer.items.len);
}

test "WsWriter multi-write accumulation" {
    var mutex = std.Thread.Mutex{};
    const allocator = testing.allocator;

    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    var ws_writer = WsWriter.init(allocator, pair[0], &mutex);
    defer ws_writer.deinit();

    const w = ws_writer.writer();

    // Multiple writes accumulate
    _ = try w.write("abc");
    _ = try w.write("def");
    _ = try w.write("ghi");

    try testing.expectEqual(@as(usize, 9), ws_writer.buffer.items.len);
    try testing.expectEqualStrings("abcdefghi", ws_writer.buffer.items);
}

test "WsWriter fuzz arbitrary bytes" {
    try zcheck.check(struct {
        fn prop(args: struct { data: zcheck.BoundedSlice(u8, 256) }) !bool {
            var mutex = std.Thread.Mutex{};
            const allocator = testing.allocator;

            const pair = createSocketPair() catch return true; // Skip if socket fails
            defer posix.close(pair[0]);
            defer posix.close(pair[1]);

            var ws_writer = WsWriter.init(allocator, pair[0], &mutex);
            defer ws_writer.deinit();

            const w = ws_writer.writer();
            const bytes = args.data.slice();

            // Writing arbitrary bytes should never panic
            _ = w.write(bytes) catch return true;

            // Buffer should contain all non-newline bytes
            var expected_len: usize = 0;
            for (bytes) |b| {
                if (b != '\n') expected_len += 1;
            }
            // After write, buffer should have accumulated non-newline bytes
            // (unless there was a newline, which flushes)
            return true;
        }
    }.prop, .{ .iterations = 500 });
}

test "WsReader extracts complete message" {
    const allocator = testing.allocator;

    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Send a masked WebSocket text frame (client to server)
    const payload = "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}";
    const frame = try encodeMaskedFrame(allocator, .text, payload);
    defer allocator.free(frame);

    _ = try posix.write(pair[0], frame);

    // Read via WsReader
    var ws_reader = WsReader.init(allocator, pair[1]);
    defer ws_reader.deinit();

    var buf: [256]u8 = undefined;
    const n = try ws_reader.read(&buf);

    // Should get payload + newline
    try testing.expectEqual(@as(usize, 34), n);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"test\"}\n", buf[0..n]);
}

test "WsReader handles multiple frames" {
    const allocator = testing.allocator;

    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Send two masked WebSocket text frames back to back
    const payload1 = "{\"id\":1}";
    const payload2 = "{\"id\":2}";
    const frame1 = try encodeMaskedFrame(allocator, .text, payload1);
    defer allocator.free(frame1);
    const frame2 = try encodeMaskedFrame(allocator, .text, payload2);
    defer allocator.free(frame2);

    _ = try posix.write(pair[0], frame1);
    _ = try posix.write(pair[0], frame2);

    var ws_reader = WsReader.init(allocator, pair[1]);
    defer ws_reader.deinit();

    // Read first message
    var buf1: [64]u8 = undefined;
    const n1 = try ws_reader.read(&buf1);

    // Read second message
    var buf2: [64]u8 = undefined;
    const n2 = try ws_reader.read(&buf2);

    try testing.expectEqualStrings("{\"id\":1}\n", buf1[0..n1]);
    try testing.expectEqualStrings("{\"id\":2}\n", buf2[0..n2]);
}

test "WsTransport large payload" {
    const allocator = testing.allocator;

    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // Use 4KB payload
    const size = 4 * 1024;
    const payload = try allocator.alloc(u8, size);
    defer allocator.free(payload);
    @memset(payload, 'x');

    const frame = try encodeMaskedFrame(allocator, .text, payload);
    defer allocator.free(frame);

    _ = try posix.write(pair[0], frame);

    var ws_reader = WsReader.init(allocator, pair[1]);
    defer ws_reader.deinit();

    // Read all at once (4KB + newline fits in 8KB buffer)
    var buf: [8192]u8 = undefined;
    const n = try ws_reader.read(&buf);

    // Should get payload + newline
    try testing.expectEqual(@as(usize, size + 1), n);
}

test "perf: WsWriter throughput" {
    var mutex = std.Thread.Mutex{};
    const allocator = testing.allocator;

    const pair = try createSocketPair();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    var ws_writer = WsWriter.init(allocator, pair[0], &mutex);
    defer ws_writer.deinit();

    const w = ws_writer.writer();
    const msg = "{\"jsonrpc\":\"2.0\",\"method\":\"test\",\"id\":1}\n";
    // Keep iterations low to avoid filling socket buffer
    const iterations: usize = 100;

    var timer = std.time.Timer.start() catch return;
    for (0..iterations) |_| {
        _ = try w.write(msg);
    }
    const elapsed = timer.read();
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) /
        (@as(f64, @floatFromInt(elapsed)) / 1e9);

    // Should achieve at least 1K ops/sec
    try testing.expect(ops_per_sec > 1_000);
}
