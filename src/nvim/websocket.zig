const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.websocket);

// Maximum frame payload size (16 MB)
pub const MAX_FRAME_SIZE: u64 = 16 * 1024 * 1024;
pub const max_handshake_bytes: usize = 4096;

fn bytesToHexLower(allocator: Allocator, bytes: []const u8) ![]u8 {
    const charset = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 0x0f];
    }
    return out;
}

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
    ws_key: []const u8,
};

pub const HandshakeParse = struct {
    result: HandshakeResult,
    header_end: usize,
};

pub fn deinitHandshakeResult(allocator: Allocator, result: *const HandshakeResult) void {
    allocator.free(result.path);
    allocator.free(result.ws_key);
}

pub fn tryParseHandshake(allocator: Allocator, buffer: []const u8) !?HandshakeParse {
    if (buffer.len > max_handshake_bytes) return error.HeadersTooLarge;
    const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return null;
    const headers_end = header_end + 4;
    const parsed = try parseHttpHeaders(allocator, buffer[0..headers_end]);
    return .{ .result = parsed, .header_end = headers_end };
}

pub fn completeHandshake(
    socket_fd: std.posix.socket_t,
    parsed: HandshakeResult,
) !ClientKind {
    // Determine client kind from path
    const path_map = std.StaticStringMap(ClientKind).initComptime(.{
        .{ "/nvim", .nvim },
        .{ "/acp", .acp },
    });
    const client_kind = path_map.get(parsed.path) orelse return error.InvalidPath;

    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(parsed.ws_key);
    hasher.update(magic);
    const digest = hasher.finalResult();

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &digest);

    const response_template = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: ";
    const response_end = "\r\n\r\n";
    try writeAll(socket_fd, response_template);
    try writeAll(socket_fd, &accept_key);
    try writeAll(socket_fd, response_end);

    return client_kind;
}

/// Parse WebSocket frame from bytes.
/// Returns frame and bytes consumed, or error.
/// Caller must copy payload if needed - it points into input buffer.
pub fn parseFrame(data: []u8) !ParseResult {
    if (data.len < 2) return error.NeedMoreData;

    const fin = (data[0] & 0x80) != 0;
    // RFC 6455 Section 5.2: RSV1, RSV2, RSV3 MUST be 0 unless extension negotiated
    if ((data[0] & 0x70) != 0) return error.ReservedBitsSet;
    const opcode = try Opcode.fromU4(@truncate(data[0] & 0x0F));
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

    // Masking key (RFC 6455: clients MUST mask frames to server)
    if (!masked) return error.UnmaskedFrame;
    var mask: [4]u8 = undefined;
    if (data.len < offset + 4) return error.NeedMoreData;
    @memcpy(&mask, data[offset..][0..4]);
    offset += 4;

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
    nvim, // Neovim plugin
    acp, // ACP (Agent Communication Protocol)
};

pub const HandshakeOutcome = struct {
    client_kind: ClientKind,
    remainder: ?[]u8 = null,
};

/// Perform WebSocket handshake on a socket.
/// Returns the client kind based on path.
pub fn performHandshakeWithPath(allocator: Allocator, socket_fd: std.posix.socket_t) !HandshakeOutcome {
    var header_buf: [max_handshake_bytes]u8 = undefined;
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

    const parsed = (try tryParseHandshake(allocator, header_buf[0..total_read])) orelse return error.HeadersTooLarge;
    defer deinitHandshakeResult(allocator, &parsed.result);

    const client_kind = try completeHandshake(socket_fd, parsed.result);

    var remainder: ?[]u8 = null;
    if (parsed.header_end < total_read) {
        remainder = try allocator.dupe(u8, header_buf[parsed.header_end..total_read]);
    }

    return .{
        .client_kind = client_kind,
        .remainder = remainder,
    };
}

fn parseHttpHeaders(allocator: Allocator, headers: []const u8) !HandshakeResult {
    var path: ?[]const u8 = null;
    errdefer if (path) |p| allocator.free(p);

    var ws_key: ?[]const u8 = null;
    errdefer if (ws_key) |k| allocator.free(k);

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
    };
}

fn parseHeader(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.ascii.startsWithIgnoreCase(line, prefix)) {
        return line[prefix.len..];
    }
    return null;
}

fn writeAll(fd: std.posix.socket_t, buf: []const u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try std.posix.write(fd, buf[offset..]);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
}

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

fn makeMaskedFrame(allocator: Allocator, opcode: u8, payload: []const u8, mask: [4]u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, 0x80 | opcode);
    if (payload.len < 126) {
        try buf.append(allocator, 0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len < 65536) {
        try buf.append(allocator, 0x80 | 126);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(payload.len)));
        try buf.appendSlice(allocator, &len_bytes);
    } else {
        try buf.append(allocator, 0x80 | 127);
        const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, @intCast(payload.len)));
        try buf.appendSlice(allocator, &len_bytes);
    }
    try buf.appendSlice(allocator, &mask);
    for (payload, 0..) |b, i| {
        try buf.append(allocator, b ^ mask[i % 4]);
    }

    return buf.toOwnedSlice(allocator);
}

test "encodeFrame small payload" {
    const allocator = testing.allocator;
    const frame = try encodeFrame(allocator, .text, "hello");
    defer allocator.free(frame);
    const summary = .{
        .first = frame[0],
        .len = frame[1],
        .payload = frame[2..],
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.encodeFrame small payload__struct_<^\d+$>
        \\  .first: u8 = 129
        \\  .len: u8 = 5
        \\  .payload: []u8
        \\    "hello"
    ).expectEqual(summary);
}

test "encodeFrame medium payload" {
    const allocator = testing.allocator;
    const payload = "x" ** 200;
    const frame = try encodeFrame(allocator, .text, payload);
    defer allocator.free(frame);
    const summary = .{
        .first = frame[0],
        .len = frame[1],
        .extended_len = std.mem.readInt(u16, frame[2..4], .big),
        .payload = frame[4..],
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.encodeFrame medium payload__struct_<^\d+$>
        \\  .first: u8 = 129
        \\  .len: u8 = 126
        \\  .extended_len: u16 = 200
        \\  .payload: []u8
        \\    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    ).expectEqual(summary);
}

test "parseFrame small unmasked" {
    // Manually construct unmasked frame (server-to-client style)
    var data = [_]u8{ 0x81, 0x05 } ++ "hello".*;

    try testing.expectError(error.UnmaskedFrame, parseFrame(&data));
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
    const summary = .{
        .fin = result.frame.fin,
        .opcode = @tagName(result.frame.opcode),
        .payload = result.frame.payload,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.parseFrame masked__struct_<^\d+$>
        \\  .fin: bool = true
        \\  .opcode: [:0]const u8
        \\    "text"
        \\  .payload: []const u8
        \\    "hello"
    ).expectEqual(summary);
}

test "parseFrame incomplete" {
    var data = [_]u8{0x81}; // Only first byte
    try testing.expectError(error.NeedMoreData, parseFrame(&data));
}

test "parseFrame ping" {
    const allocator = testing.allocator;
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
    const data = try makeMaskedFrame(allocator, @intFromEnum(Opcode.ping), "", mask);
    defer allocator.free(data);

    const result = try parseFrame(data);
    const summary = .{
        .opcode = @tagName(result.frame.opcode),
        .payload_len = result.frame.payload.len,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.parseFrame ping__struct_<^\d+$>
        \\  .opcode: [:0]const u8
        \\    "ping"
        \\  .payload_len: usize = 0
    ).expectEqual(summary);
}

test "parseFrame close" {
    const allocator = testing.allocator;
    const mask = [4]u8{ 0x01, 0x02, 0x03, 0x04 };
    const payload = [_]u8{ 0x03, 0xe8 };
    const data = try makeMaskedFrame(allocator, @intFromEnum(Opcode.close), &payload, mask);
    defer allocator.free(data);

    const result = try parseFrame(data);
    const summary = .{
        .opcode = @tagName(result.frame.opcode),
        .payload_len = result.frame.payload.len,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.parseFrame close__struct_<^\d+$>
        \\  .opcode: [:0]const u8
        \\    "close"
        \\  .payload_len: usize = 2
    ).expectEqual(summary);
}

test "parseFrame reserved opcode" {
    const allocator = testing.allocator;
    const mask = [4]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    const data = try makeMaskedFrame(allocator, 0x3, "", mask);
    defer allocator.free(data);
    try testing.expectError(error.ReservedOpcode, parseFrame(data));
}

test "tryParseHandshake returns null for partial headers" {
    const allocator = testing.allocator;
    const partial = "GET /nvim HTTP/1.1\r\nHost: localhost\r\n";
    const parsed = try tryParseHandshake(allocator, partial);
    try testing.expect(parsed == null);
}

test "tryParseHandshake parses complete headers" {
    const allocator = testing.allocator;
    const request =
        "GET /nvim HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "\r\n";
    const parsed = (try tryParseHandshake(allocator, request)) orelse return error.TestExpectedEqual;
    defer deinitHandshakeResult(allocator, &parsed.result);
    const summary = .{
        .path = parsed.result.path,
        .has_header_end = parsed.header_end > 0,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.tryParseHandshake parses complete headers__struct_<^\d+$>
        \\  .path: []const u8
        \\    "/nvim"
        \\  .has_header_end: bool = true
    ).expectEqual(summary);
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

    const request =
        "GET /nvim HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "\r\n";
    const extra = [_]u8{ 0x81, 0x00 };
    var write_buf: [request.len + extra.len]u8 = undefined;
    @memcpy(write_buf[0..request.len], request);
    @memcpy(write_buf[request.len..], &extra);
    try writeAll(client, &write_buf);

    const outcome = try performHandshakeWithPath(testing.allocator, server);
    defer if (outcome.remainder) |bytes| testing.allocator.free(bytes);

    const remainder_hex: ?[]const u8 = if (outcome.remainder) |bytes|
        try bytesToHexLower(testing.allocator, bytes)
    else
        null;
    defer if (remainder_hex) |hex| testing.allocator.free(hex);

    const summary = .{
        .client_kind = @tagName(outcome.client_kind),
        .remainder_hex = remainder_hex,
    };
    try (ohsnap{}).snap(@src(),
        \\nvim.websocket.test.performHandshakeWithPath preserves trailing bytes__struct_<^\d+$>
        \\  .client_kind: [:0]const u8
        \\    "nvim"
        \\  .remainder_hex: ?[]const u8
        \\    "8100"
    ).expectEqual(summary);
}
