const std = @import("std");
const io_utils = @import("core/io_utils.zig");
const Allocator = std.mem.Allocator;
const max_jsonrpc_line_bytes: usize = 4 * 1024 * 1024;

/// JSON-RPC 2.0 Request
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?Id = null,

    pub const Id = union(enum) {
        string: []const u8,
        number: i64,
        null,

        pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Id {
            const value = try std.json.Value.jsonParse(allocator, source, options);
            return jsonParseFromValue(allocator, value, options);
        }

        pub fn jsonParseFromValue(
            allocator: Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) std.json.ParseFromValueError!Id {
            _ = allocator;
            _ = options;
            return switch (source) {
                .string => |str| .{ .string = str },
                .integer => |int| .{ .number = int },
                .null => .null,
                else => error.UnexpectedToken,
            };
        }
    };

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }
};

/// JSON-RPC 2.0 Notification (no id)
pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};

/// JSON-RPC 2.0 Response
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    @"error": ?Error = null,
    id: ?Request.Id,

    pub fn success(id: ?Request.Id, result: std.json.Value) Response {
        return .{ .id = id, .result = result };
    }

    pub fn err(id: ?Request.Id, code: i32, message: []const u8) Response {
        return .{ .id = id, .@"error" = .{ .code = code, .message = message } };
    }
};

/// JSON-RPC 2.0 Error
pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,

    // Standard error codes
    pub const ParseError = -32700;
    pub const InvalidRequest = -32600;
    pub const MethodNotFound = -32601;
    pub const InvalidParams = -32602;
    pub const InternalError = -32603;

    // ACP-specific error codes
    pub const AuthRequired = -32000;
};

/// JSON-RPC 2.0 Message
pub const Message = union(enum) {
    request: Request,
    notification: Notification,
    response: Response,
};

const Envelope = struct {
    jsonrpc: []const u8 = "2.0",
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    id: ?Request.Id = null,
    result: ?std.json.Value = null,
    @"error": ?Error = null,
};

/// Parsed request with owned memory
pub const ParsedRequest = struct {
    request: Request,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
    }
};

/// Parsed message with owned memory
pub const ParsedMessage = struct {
    message: Message,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedMessage) void {
        self.arena.deinit();
    }
};

/// Parse a JSON-RPC request from a JSON string
pub fn parseRequest(allocator: Allocator, json_str: []const u8) !ParsedRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), json_str, .{
        .ignore_unknown_fields = true,
    });
    const env = parsed.value;

    if (!std.mem.eql(u8, env.jsonrpc, "2.0")) return error.InvalidRequest;
    const method = env.method orelse return error.InvalidRequest;

    const request = Request{
        .method = method,
        .params = env.params,
        .id = env.id,
    };
    return .{ .request = request, .arena = arena };
}

/// Parse a JSON-RPC message (request/notification/response)
pub fn parseMessage(allocator: Allocator, json_str: []const u8) !ParsedMessage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), json_str, .{
        .ignore_unknown_fields = true,
    });
    const message = try parseMessageFromEnvelope(parsed.value);
    return .{ .message = message, .arena = arena };
}

fn parseMessageFromEnvelope(env: Envelope) !Message {
    if (!std.mem.eql(u8, env.jsonrpc, "2.0")) return error.InvalidRequest;

    if (env.method) |method| {
        if (env.id != null) {
            return .{
                .request = .{
                    .method = method,
                    .params = env.params,
                    .id = env.id,
                },
            };
        }
        return .{
            .notification = .{
                .method = method,
                .params = env.params,
            },
        };
    }

    if (env.result == null and env.@"error" == null) return error.InvalidRequest;
    if (env.id == null) return error.InvalidRequest;

    return .{
        .response = .{
            .id = env.id,
            .result = env.result,
            .@"error" = env.@"error",
        },
    };
}

/// Serialize a response to JSON using std.json.Stringify
pub fn serializeResponse(allocator: Allocator, response: Response) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");

    if (response.result) |result| {
        try jw.objectField("result");
        try result.jsonStringify(&jw);
    }

    if (response.@"error") |err_val| {
        try jw.objectField("error");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(err_val.code);
        try jw.objectField("message");
        try jw.write(err_val.message);
        if (err_val.data) |data| {
            try jw.objectField("data");
            try data.jsonStringify(&jw);
        }
        try jw.endObject();
    }

    try jw.objectField("id");
    if (response.id) |id| {
        switch (id) {
            .string => |s| try jw.write(s),
            .number => |n| try jw.write(n),
            .null => try jw.write(null),
        }
    } else {
        try jw.write(null);
    }

    try jw.endObject();
    return out.toOwnedSlice();
}

pub fn serializeTypedResponse(
    allocator: Allocator,
    id: ?Request.Id,
    result: anytype,
    options: std.json.Stringify.Options,
) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = options,
    };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("result");
    try jw.write(result);
    try jw.objectField("id");
    if (id) |i| {
        switch (i) {
            .string => |s| try jw.write(s),
            .number => |n| try jw.write(n),
            .null => try jw.write(null),
        }
    } else {
        try jw.write(null);
    }
    try jw.endObject();

    return try out.toOwnedSlice();
}

pub fn serializeTypedNotification(
    allocator: Allocator,
    method: []const u8,
    params: anytype,
    options: std.json.Stringify.Options,
) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = options,
    };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(method);
    try jw.objectField("params");
    try jw.write(params);
    try jw.endObject();

    return try out.toOwnedSlice();
}

/// Serialize a notification to JSON using std.json.Stringify
pub fn serializeNotification(allocator: Allocator, notification: Notification) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(notification.method);

    if (notification.params) |params| {
        try jw.objectField("params");
        try params.jsonStringify(&jw);
    }

    try jw.endObject();
    return out.toOwnedSlice();
}

/// Serialize a request to JSON using std.json.Stringify
pub fn serializeRequest(allocator: Allocator, request: Request) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("method");
    try jw.write(request.method);

    if (request.params) |params| {
        try jw.objectField("params");
        try params.jsonStringify(&jw);
    }

    if (request.id) |id| {
        try jw.objectField("id");
        switch (id) {
            .string => |s| try jw.write(s),
            .number => |n| try jw.write(n),
            .null => try jw.write(null),
        }
    }

    try jw.endObject();
    return out.toOwnedSlice();
}

/// JSON-RPC message reader - reads newline-delimited JSON from a stream
pub const Reader = struct {
    stream: std.io.AnyReader,
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    fd: ?std.posix.fd_t = null,

    pub fn init(allocator: Allocator, stream: std.io.AnyReader) Reader {
        return .{
            .stream = stream,
            .allocator = allocator,
            .buffer = .empty,
            .fd = null,
        };
    }

    pub fn initWithFd(allocator: Allocator, stream: std.io.AnyReader, fd: std.posix.fd_t) Reader {
        return .{
            .stream = stream,
            .allocator = allocator,
            .buffer = .empty,
            .fd = fd,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.buffer.deinit(self.allocator);
    }

    /// Read the next JSON-RPC message (newline-delimited)
    pub fn next(self: *Reader) !?ParsedRequest {
        self.buffer.clearRetainingCapacity();

        // Read until newline
        while (true) {
            const byte = self.stream.readByte() catch |e| switch (e) {
                error.EndOfStream => {
                    if (self.buffer.items.len == 0) return null;
                    break;
                },
                else => return e,
            };

            if (byte == '\n') break;
            try self.buffer.append(self.allocator, byte);
            if (self.buffer.items.len > max_jsonrpc_line_bytes) return error.LineTooLong;
        }

        if (self.buffer.items.len == 0) return null;

        const parsed = try parseRequest(self.allocator, self.buffer.items);
        return parsed;
    }

    /// Read the next JSON-RPC message (request/notification/response)
    pub fn nextMessage(self: *Reader) !?ParsedMessage {
        self.buffer.clearRetainingCapacity();

        while (true) {
            const byte = self.stream.readByte() catch |e| switch (e) {
                error.EndOfStream => {
                    if (self.buffer.items.len == 0) return null;
                    break;
                },
                else => return e,
            };

            if (byte == '\n') break;
            try self.buffer.append(self.allocator, byte);
            if (self.buffer.items.len > max_jsonrpc_line_bytes) return error.LineTooLong;
        }

        if (self.buffer.items.len == 0) return null;

        return try parseMessage(self.allocator, self.buffer.items);
    }

    /// Read the next JSON-RPC message with a deadline (milliseconds since epoch).
    pub fn nextMessageWithTimeout(self: *Reader, deadline_ms: i64) !?ParsedMessage {
        if (self.fd == null) {
            return self.nextMessage();
        }
        self.buffer.clearRetainingCapacity();

        while (true) {
            const now = std.time.milliTimestamp();
            if (now >= deadline_ms) return error.Timeout;
            const timeout_ms = io_utils.pollSliceMs(deadline_ms, now);
            const ready = try io_utils.waitForReadable(self.fd.?, timeout_ms);
            if (!ready) continue;

            const byte = self.stream.readByte() catch |e| switch (e) {
                error.EndOfStream => {
                    if (self.buffer.items.len == 0) return null;
                    break;
                },
                else => return e,
            };

            if (byte == '\n') break;
            try self.buffer.append(self.allocator, byte);
            if (self.buffer.items.len > max_jsonrpc_line_bytes) return error.LineTooLong;
        }

        if (self.buffer.items.len == 0) return null;

        return try parseMessage(self.allocator, self.buffer.items);
    }
};

/// JSON-RPC message writer - writes newline-delimited JSON to a stream
pub const Writer = struct {
    stream: std.io.AnyWriter,
    allocator: Allocator,

    pub fn init(allocator: Allocator, stream: std.io.AnyWriter) Writer {
        return .{
            .stream = stream,
            .allocator = allocator,
        };
    }

    pub fn writeResponse(self: *Writer, response: Response) !void {
        const json = try serializeResponse(self.allocator, response);
        defer self.allocator.free(json);
        try self.stream.writeAll(json);
        try self.stream.writeByte('\n');
    }

    /// Write a response with a typed result (avoids Value intermediary)
    pub fn writeTypedResponse(self: *Writer, id: ?Request.Id, result: anytype) !void {
        const json = try serializeTypedResponse(self.allocator, id, result, .{});
        defer self.allocator.free(json);
        try self.stream.writeAll(json);
        try self.stream.writeByte('\n');
    }

    pub fn writeNotification(self: *Writer, notification: Notification) !void {
        const json = try serializeNotification(self.allocator, notification);
        defer self.allocator.free(json);
        try self.stream.writeAll(json);
        try self.stream.writeByte('\n');
    }

    /// Write a notification with typed params (avoids Value intermediary)
    pub fn writeTypedNotification(self: *Writer, method: []const u8, params: anytype) !void {
        const json = try serializeTypedNotification(
            self.allocator,
            method,
            params,
            .{ .emit_null_optional_fields = false },
        );
        defer self.allocator.free(json);
        try self.stream.writeAll(json);
        try self.stream.writeByte('\n');
    }

    /// Write a request (for bidirectional communication)
    pub fn writeRequest(self: *Writer, request: Request) !void {
        const json = try serializeRequest(self.allocator, request);
        defer self.allocator.free(json);
        try self.stream.writeAll(json);
        try self.stream.writeByte('\n');
    }

    /// Write a request with typed params (avoids Value intermediary)
    pub fn writeTypedRequest(self: *Writer, id: Request.Id, method: []const u8, params: anytype) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write(method);
        try jw.objectField("params");
        try jw.write(params);
        try jw.objectField("id");
        switch (id) {
            .string => |s| try jw.write(s),
            .number => |n| try jw.write(n),
            .null => try jw.write(null),
        }
        try jw.endObject();

        const json = try out.toOwnedSlice();
        defer self.allocator.free(json);
        try self.stream.writeAll(json);
        try self.stream.writeByte('\n');
    }
};

// Tests
const testing = std.testing;

test "parse request with string id" {
    const json =
        \\{"jsonrpc":"2.0","method":"test","id":"abc"}
    ;
    var parsed = try parseRequest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("test", parsed.request.method);
    try testing.expectEqualStrings("abc", parsed.request.id.?.string);
}

test "parse request with number id" {
    const json =
        \\{"jsonrpc":"2.0","method":"test","id":42}
    ;
    var parsed = try parseRequest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("test", parsed.request.method);
    try testing.expectEqual(@as(i64, 42), parsed.request.id.?.number);
}

test "parse notification (no id)" {
    const json =
        \\{"jsonrpc":"2.0","method":"notify"}
    ;
    var parsed = try parseRequest(testing.allocator, json);
    defer parsed.deinit();
    try testing.expectEqualStrings("notify", parsed.request.method);
    try testing.expect(parsed.request.isNotification());
}

test "Reader nextMessageWithTimeout returns timeout" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    const file = std.fs.File{ .handle = fds[0] };
    var reader = Reader.initWithFd(testing.allocator, file.deprecatedReader().any(), fds[0]);
    defer reader.deinit();

    const deadline_ms = std.time.milliTimestamp() - 1;
    try testing.expectError(error.Timeout, reader.nextMessageWithTimeout(deadline_ms));
}

test "serialize success response" {
    const response = Response.success(.{ .number = 1 }, .{ .bool = true });
    const json = try serializeResponse(testing.allocator, response);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":1}", json);
}

test "serialize error response" {
    const response = Response.err(.{ .number = 1 }, Error.MethodNotFound, "Method not found");
    const json = try serializeResponse(testing.allocator, response);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":1}", json);
}

// Property tests
const quickcheck = @import("util/quickcheck.zig");

test "property: response with numeric id roundtrips through JSON" {
    try quickcheck.check(struct {
        fn prop(args: struct { id: i64, result_bool: bool }) bool {
            const response = Response.success(
                .{ .number = args.id },
                .{ .bool = args.result_bool },
            );

            const json = serializeResponse(testing.allocator, response) catch return false;
            defer testing.allocator.free(json);

            // Parse it back
            const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch return false;
            defer parsed.deinit();

            const obj = parsed.value.object;

            // Verify structure
            const jsonrpc = obj.get("jsonrpc") orelse return false;
            if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) return false;

            const id_val = obj.get("id") orelse return false;
            if (id_val != .integer or id_val.integer != args.id) return false;

            const result = obj.get("result") orelse return false;
            if (result != .bool or result.bool != args.result_bool) return false;

            return true;
        }
    }.prop, .{});
}

test "property: error response preserves error code" {
    try quickcheck.check(struct {
        fn prop(args: struct { id: i64, code: i32 }) bool {
            const response = Response.err(.{ .number = args.id }, args.code, "test error");

            const json = serializeResponse(testing.allocator, response) catch return false;
            defer testing.allocator.free(json);

            const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch return false;
            defer parsed.deinit();

            const obj = parsed.value.object;
            const err_obj = (obj.get("error") orelse return false).object;
            const code = (err_obj.get("code") orelse return false).integer;

            return code == args.code;
        }
    }.prop, .{});
}

test "property: request id types are preserved" {
    try quickcheck.check(struct {
        fn prop(args: struct { id: i64 }) bool {
            // Test numeric ID roundtrip through request serialization
            const request = Request{
                .method = "test",
                .id = .{ .number = args.id },
            };

            const json = serializeRequest(testing.allocator, request) catch return false;
            defer testing.allocator.free(json);

            var parsed_req = parseRequest(testing.allocator, json) catch return false;
            defer parsed_req.deinit();

            const parsed_id = parsed_req.request.id orelse return false;
            return switch (parsed_id) {
                .number => |n| n == args.id,
                else => false,
            };
        }
    }.prop, .{});
}

// =============================================================================
// Snapshot Tests for JSON-RPC Responses
// =============================================================================

const ohsnap = @import("ohsnap");

test "snapshot: success response with object result" {
    var result_obj = std.json.ObjectMap.init(testing.allocator);
    defer result_obj.deinit();
    try result_obj.put("sessionId", .{ .string = "abc123" });
    try result_obj.put("status", .{ .string = "active" });

    const response = Response.success(.{ .number = 1 }, .{ .object = result_obj });
    const json = try serializeResponse(testing.allocator, response);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","result":{"sessionId":"abc123","status":"active"},"id":1}
    ).diff(json, true);
}

test "snapshot: error response with code and message" {
    const response = Response.err(.{ .string = "req-42" }, Error.MethodNotFound, "Unknown method");
    const json = try serializeResponse(testing.allocator, response);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Unknown method"},"id":"req-42"}
    ).diff(json, true);
}

test "snapshot: notification without id" {
    var params = std.json.ObjectMap.init(testing.allocator);
    defer params.deinit();
    try params.put("event", .{ .string = "connected" });

    const notification = Notification{
        .method = "session/update",
        .params = .{ .object = params },
    };
    const json = try serializeNotification(testing.allocator, notification);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"session/update","params":{"event":"connected"}}
    ).diff(json, true);
}

test "snapshot: request with null id" {
    const request = Request{
        .method = "initialize",
        .id = .null,
    };
    const json = try serializeRequest(testing.allocator, request);
    defer testing.allocator.free(json);

    try (ohsnap{}).snap(@src(),
        \\{"jsonrpc":"2.0","method":"initialize","id":null}
    ).diff(json, true);
}
