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

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

pub const ParseResult = struct {
    frame: Frame,
    consumed: usize,
};

pub const HandshakeResult = struct {
    path: []const u8,
    auth_token: ?[]const u8,
    ws_key: []const u8,
};

/// Parse WebSocket frame from bytes.
/// Returns frame and bytes consumed, or error.
/// Caller must copy payload if needed - it points into input buffer.
pub fn parseFrame(data: []u8) !ParseResult {
    if (data.len < 2) return error.NeedMoreData;

    const fin = (data[0] & 0x80) != 0;
    // RFC 6455 Section 5.2: RSV1, RSV2, RSV3 MUST be 0 unless extension negotiated
    if ((data[0] & 0x70) != 0) return error.ReservedBitsSet;
    const opcode = Opcode.fromU4(@truncate(data[0] & 0x0F)) catch return error.ReservedOpcode;
    const masked = (data[1] & 0x80) != 0;
    var payload_len: u64 = data[1] & 0x7F;

    // RFC 6455 Section 5.5: Control frames MUST NOT be fragmented
    if (opcode.isControl() and !fin) return error.FragmentedControlFrame;
    // RFC 6455 Section 5.5: Control frame payload MUST be <= 125 bytes
    if (opcode.isControl() and payload_len > 125) return error.ControlFrameTooLarge;

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

pub const ClientKind = enum {
    mcp, // Claude CLI with auth token
    nvim, // Neovim plugin (no auth)
};

pub const HandshakeOutcome = struct {
    client_kind: ClientKind,
    remainder: ?[]u8 = null,
};

/// Perform WebSocket handshake on a socket.
/// Returns the client kind based on path.
pub fn performHandshakeWithPath(allocator: Allocator, socket_fd: std.posix.socket_t, expected_auth_token: []const u8) !HandshakeOutcome {
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

    const split = try splitHeaders(header_buf[0..total_read]);
    const parsed = try parseHttpHeaders(allocator, split.headers);
    defer {
        if (parsed.auth_token) |t| allocator.free(t);
        allocator.free(parsed.ws_key);
        allocator.free(parsed.path);
    }

    // Determine client kind from path
    const client_kind: ClientKind = if (std.mem.eql(u8, parsed.path, "/nvim"))
        .nvim
    else
        .mcp;

    // Validate auth token for MCP clients only
    if (client_kind == .mcp) {
        if (parsed.auth_token) |token| {
            if (!std.mem.eql(u8, token, expected_auth_token)) {
                return error.InvalidAuthToken;
            }
        } else {
            return error.MissingAuthToken;
        }
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

    var remainder: ?[]u8 = null;
    if (split.remainder.len > 0) {
        remainder = try allocator.dupe(u8, split.remainder);
    }

    return .{
        .client_kind = client_kind,
        .remainder = remainder,
    };
}

/// Perform WebSocket handshake on a socket (MCP auth required).
/// Legacy function for backwards compatibility.
pub fn performHandshake(allocator: Allocator, socket_fd: std.posix.socket_t, expected_auth_token: []const u8) !void {
    const outcome = try performHandshakeWithPath(allocator, socket_fd, expected_auth_token);
    defer if (outcome.remainder) |extra| allocator.free(extra);
    if (outcome.client_kind != .mcp) {
        return error.InvalidPath;
    }
}

fn splitHeaders(buffer: []const u8) !struct { headers: []const u8, remainder: []const u8 } {
    const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return error.HeadersTooLarge;
    const headers_end = header_end + 4;
    return .{
        .headers = buffer[0..headers_end],
        .remainder = buffer[headers_end..],
    };
}

fn parseHttpHeaders(allocator: Allocator, headers: []const u8) !HandshakeResult {
    var path: ?[]const u8 = null;
    errdefer if (path) |p| allocator.free(p);

    var ws_key: ?[]const u8 = null;
    errdefer if (ws_key) |k| allocator.free(k);

    var auth_token: ?[]const u8 = null;
    errdefer if (auth_token) |t| allocator.free(t);

    // RFC 6455 required headers
    var has_upgrade = false;
    var has_connection_upgrade = false;
    var has_version_13 = false;

    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    var first_line = true;
    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (first_line) {
            first_line = false;
            // Parse request line: "GET /path HTTP/1.1"
            var parts = std.mem.splitScalar(u8, line, ' ');
            const method = parts.next() orelse return error.MalformedRequest;
            // RFC 6455: WebSocket handshake MUST be GET
            if (!std.mem.eql(u8, method, "GET")) {
                return error.InvalidHttpMethod;
            }
            if (parts.next()) |p| {
                path = try allocator.dupe(u8, p);
            }
            continue;
        }

        if (parseHeader(line, "Sec-WebSocket-Key: ")) |value| {
            ws_key = try allocator.dupe(u8, value);
        } else if (parseHeader(line, "x-claude-code-ide-authorization: ")) |value| {
            auth_token = try allocator.dupe(u8, value);
        } else if (std.ascii.startsWithIgnoreCase(line, "Upgrade:")) {
            // Check for "websocket" (case-insensitive)
            const value = std.mem.trim(u8, line["Upgrade:".len..], " \t");
            if (std.ascii.eqlIgnoreCase(value, "websocket")) {
                has_upgrade = true;
            }
        } else if (std.ascii.startsWithIgnoreCase(line, "Connection:")) {
            // Check for "Upgrade" in Connection header (may have multiple values)
            const value = line["Connection:".len..];
            if (std.ascii.indexOfIgnoreCase(value, "upgrade") != null) {
                has_connection_upgrade = true;
            }
        } else if (parseHeader(line, "Sec-WebSocket-Version: ")) |value| {
            if (std.mem.eql(u8, value, "13")) {
                has_version_13 = true;
            }
        }
    }

    // RFC 6455 Section 4.2.1: Server MUST validate these headers
    if (!has_upgrade) return error.MissingUpgradeHeader;
    if (!has_connection_upgrade) return error.MissingConnectionUpgrade;
    if (!has_version_13) return error.UnsupportedWebSocketVersion;
    if (ws_key == null) return error.MissingWebSocketKey;

    // Ensure path is always allocated
    const final_path = path orelse try allocator.dupe(u8, "/");

    return .{
        .path = final_path,
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

test "performHandshakeWithPath preserves trailing bytes" {
    const listener = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(listener);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(listener, &addr.any, addr.getOsSockLen());
    try std.posix.listen(listener, 1);

    var bound_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var addr_len: std.posix.socklen_t = bound_addr.getOsSockLen();
    try std.posix.getsockname(listener, &bound_addr.any, &addr_len);
    const port = bound_addr.getPort();

    const client = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(client);
    var connect_addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    try std.posix.connect(client, &connect_addr.any, connect_addr.getOsSockLen());

    const server = try std.posix.accept(listener, null, null, 0);
    defer std.posix.close(server);

    const auth = "token-123";
    const request =
        "GET /nvim HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "x-claude-code-ide-authorization: token-123\r\n" ++
        "\r\n";
    const extra = [_]u8{ 0x81, 0x00 };
    var write_buf: [request.len + extra.len]u8 = undefined;
    @memcpy(write_buf[0..request.len], request);
    @memcpy(write_buf[request.len..], &extra);
    _ = try std.posix.write(client, &write_buf);

    const outcome = try performHandshakeWithPath(testing.allocator, server, auth);
    defer if (outcome.remainder) |bytes| testing.allocator.free(bytes);

    try testing.expectEqual(ClientKind.nvim, outcome.client_kind);
    try testing.expect(outcome.remainder != null);
    try testing.expectEqualSlices(u8, &extra, outcome.remainder.?);
}
