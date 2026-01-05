const std = @import("std");
const Allocator = std.mem.Allocator;

// Maximum frame payload size (16 MB)
pub const MAX_FRAME_SIZE: u64 = 16 * 1024 * 1024;

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    pub fn fromU4(value: u4) error{ReservedOpcode}!Opcode {
        return switch (value) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => error.ReservedOpcode,
        };
    }
};

pub const ParseResult = struct {
    frame: Frame,
    consumed: usize,
};

pub const HandshakeResult = struct {
    auth_token: ?[]const u8,
    ws_key: []const u8,
};

/// Parse WebSocket frame from bytes.
/// Returns frame and bytes consumed, or error.
/// Caller must copy payload if needed - it points into input buffer.
pub fn parseFrame(data: []u8) !ParseResult {
    if (data.len < 2) return error.NeedMoreData;

    const fin = (data[0] & 0x80) != 0;
    const opcode = Opcode.fromU4(@truncate(data[0] & 0x0F)) catch return error.ReservedOpcode;
    const masked = (data[1] & 0x80) != 0;
    var payload_len: u64 = data[1] & 0x7F;

    var offset: usize = 2;

    // Extended payload length
    if (payload_len == 126) {
        if (data.len < 4) return error.NeedMoreData;
        payload_len = std.mem.readInt(u16, data[2..4], .big);
        offset = 4;
    } else if (payload_len == 127) {
        if (data.len < 10) return error.NeedMoreData;
        payload_len = std.mem.readInt(u64, data[2..10], .big);
        offset = 10;
    }

    // Reject oversized frames
    if (payload_len > MAX_FRAME_SIZE) return error.FrameTooLarge;

    // Masking key (clients always mask)
    var mask: [4]u8 = undefined;
    if (masked) {
        if (data.len < offset + 4) return error.NeedMoreData;
        @memcpy(&mask, data[offset..][0..4]);
        offset += 4;
    }

    // Payload
    const payload_len_usize: usize = @intCast(payload_len);
    const payload_end = offset + payload_len_usize;
    if (data.len < payload_end) return error.NeedMoreData;

    const payload = data[offset..payload_end];

    // Unmask in place if needed
    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % 4];
        }
    }

    return .{
        .frame = Frame{ .fin = fin, .opcode = opcode, .payload = payload },
        .consumed = payload_end,
    };
}

/// Encode WebSocket frame (server never masks).
pub fn encodeFrame(allocator: Allocator, opcode: Opcode, payload: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // FIN + opcode
    try buf.append(allocator, 0x80 | @as(u8, @intFromEnum(opcode)));

    // Payload length (no mask bit for server)
    if (payload.len < 126) {
        try buf.append(allocator, @intCast(payload.len));
    } else if (payload.len < 65536) {
        try buf.append(allocator, 126);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len)));
        try buf.appendSlice(allocator, &len_bytes);
    } else {
        try buf.append(allocator, 127);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, payload.len));
        try buf.appendSlice(allocator, &len_bytes);
    }

    try buf.appendSlice(allocator, payload);
    return buf.toOwnedSlice(allocator);
}

/// Perform WebSocket handshake on a socket.
/// Returns auth token from header if present.
pub fn performHandshake(allocator: Allocator, socket_fd: std.posix.socket_t, expected_auth_token: []const u8) !void {
    var header_buf: [4096]u8 = undefined;
    var total_read: usize = 0;

    // Read until we see \r\n\r\n
    while (total_read < header_buf.len) {
        const n = std.posix.read(socket_fd, header_buf[total_read..]) catch |err| {
            return switch (err) {
                error.WouldBlock => error.NeedMoreData,
                else => err,
            };
        };
        if (n == 0) return error.ConnectionClosed;
        total_read += n;

        // Check for end of headers
        if (std.mem.indexOf(u8, header_buf[0..total_read], "\r\n\r\n")) |_| {
            break;
        }
    }

    const headers = header_buf[0..total_read];
    const parsed = try parseHttpHeaders(allocator, headers);
    defer {
        if (parsed.auth_token) |t| allocator.free(t);
        allocator.free(parsed.ws_key);
    }

    // Validate auth token
    if (parsed.auth_token) |token| {
        if (!std.mem.eql(u8, token, expected_auth_token)) {
            return error.InvalidAuthToken;
        }
    } else {
        return error.MissingAuthToken;
    }

    // Compute accept key
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(parsed.ws_key);
    hasher.update(magic);
    const digest = hasher.finalResult();

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &digest);

    // Send upgrade response
    const response_template = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: ";
    const response_end = "\r\n\r\n";

    _ = try std.posix.write(socket_fd, response_template);
    _ = try std.posix.write(socket_fd, &accept_key);
    _ = try std.posix.write(socket_fd, response_end);
}

fn parseHttpHeaders(allocator: Allocator, headers: []const u8) !HandshakeResult {
    var ws_key: ?[]const u8 = null;
    errdefer if (ws_key) |k| allocator.free(k);

    var auth_token: ?[]const u8 = null;
    errdefer if (auth_token) |t| allocator.free(t);

    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (parseHeader(line, "Sec-WebSocket-Key: ")) |value| {
            ws_key = try allocator.dupe(u8, value);
        } else if (parseHeader(line, "x-claude-code-ide-authorization: ")) |value| {
            auth_token = try allocator.dupe(u8, value);
        }
    }

    if (ws_key == null) {
        return error.MissingWebSocketKey;
    }

    return .{
        .ws_key = ws_key.?,
        .auth_token = auth_token,
    };
}

fn parseHeader(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.ascii.startsWithIgnoreCase(line, prefix)) {
        return line[prefix.len..];
    }
    return null;
}

// Tests
const testing = std.testing;

test "encodeFrame small payload" {
    const allocator = testing.allocator;
    const frame = try encodeFrame(allocator, .text, "hello");
    defer allocator.free(frame);

    try testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN + text
    try testing.expectEqual(@as(u8, 5), frame[1]); // length
    try testing.expectEqualStrings("hello", frame[2..]);
}

test "encodeFrame medium payload" {
    const allocator = testing.allocator;
    const payload = "x" ** 200;
    const frame = try encodeFrame(allocator, .text, payload);
    defer allocator.free(frame);

    try testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN + text
    try testing.expectEqual(@as(u8, 126), frame[1]); // extended length marker
    try testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, frame[2..4], .big));
    try testing.expectEqualStrings(payload, frame[4..]);
}

test "parseFrame small unmasked" {
    // Manually construct unmasked frame (server-to-client style)
    var data = [_]u8{ 0x81, 0x05 } ++ "hello".*;

    const result = try parseFrame(&data);
    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.text, result.frame.opcode);
    try testing.expectEqualStrings("hello", result.frame.payload);
    try testing.expectEqual(@as(usize, 7), result.consumed);
}

test "parseFrame masked" {
    // Masked frame from client
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const original = "hello";
    var masked: [5]u8 = undefined;
    for (original, 0..) |c, i| {
        masked[i] = c ^ mask[i % 4];
    }

    var data: [11]u8 = undefined;
    data[0] = 0x81; // FIN + text
    data[1] = 0x85; // masked + length 5
    @memcpy(data[2..6], &mask);
    @memcpy(data[6..11], &masked);

    const result = try parseFrame(&data);
    try testing.expect(result.frame.fin);
    try testing.expectEqual(Opcode.text, result.frame.opcode);
    try testing.expectEqualStrings("hello", result.frame.payload);
}

test "parseFrame incomplete" {
    var data = [_]u8{0x81}; // Only first byte
    try testing.expectError(error.NeedMoreData, parseFrame(&data));
}

test "parseFrame ping" {
    var data = [_]u8{ 0x89, 0x00 }; // FIN + ping, no payload

    const result = try parseFrame(&data);
    try testing.expectEqual(Opcode.ping, result.frame.opcode);
    try testing.expectEqual(@as(usize, 0), result.frame.payload.len);
}

test "parseFrame close" {
    var data = [_]u8{ 0x88, 0x02, 0x03, 0xe8 }; // Close with status 1000

    const result = try parseFrame(&data);
    try testing.expectEqual(Opcode.close, result.frame.opcode);
    try testing.expectEqual(@as(usize, 2), result.frame.payload.len);
}

test "parseFrame reserved opcode" {
    var data = [_]u8{ 0x83, 0x00 }; // Reserved opcode 0x3
    try testing.expectError(error.ReservedOpcode, parseFrame(&data));
}
