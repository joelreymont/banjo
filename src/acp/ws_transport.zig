const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const websocket = @import("../nvim/websocket.zig");
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
        const self: *WsWriter = @constCast(@ptrCast(@alignCast(context)));

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
        const self: *WsReader = @constCast(@ptrCast(@alignCast(context)));
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

test "WsWriter buffers until newline" {
    var mutex = std.Thread.Mutex{};
    // Can't easily test actual socket writes, but we can verify buffer behavior
    const allocator = testing.allocator;

    // Create a mock socket pair for testing
    var pair: [2]posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) {
        return error.SocketPairFailed;
    }
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
