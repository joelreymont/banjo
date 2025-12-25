const std = @import("std");
const Allocator = std.mem.Allocator;

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
    };

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }
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

/// Notification (no id, no response expected)
pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};

/// Parsed request with owned memory
pub const ParsedRequest = struct {
    request: Request,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
    }
};

/// Parse a JSON-RPC request from a JSON string
pub fn parseRequest(allocator: Allocator, json_str: []const u8) !ParsedRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json_str, .{});
    // Don't deinit - arena owns the memory

    const request = try parseRequestFromValue(parsed.value);
    return .{ .request = request, .arena = arena };
}

fn parseRequestFromValue(value: std.json.Value) !Request {
    if (value != .object) return error.InvalidRequest;
    const obj = value.object;

    // Check jsonrpc version
    const jsonrpc = obj.get("jsonrpc") orelse return error.InvalidRequest;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidRequest;
    }

    // Get method
    const method_val = obj.get("method") orelse return error.InvalidRequest;
    if (method_val != .string) return error.InvalidRequest;

    // Get optional params
    const params = obj.get("params");

    // Get optional id
    const id: ?Request.Id = if (obj.get("id")) |id_val| switch (id_val) {
        .string => |s| .{ .string = s },
        .integer => |n| .{ .number = n },
        .null => .null,
        else => return error.InvalidRequest,
    } else null;

    return Request{
        .method = method_val.string,
        .params = params,
        .id = id,
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

/// JSON-RPC message reader - reads newline-delimited JSON from a stream
pub const Reader = struct {
    stream: std.io.AnyReader,
    allocator: Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: Allocator, stream: std.io.AnyReader) Reader {
        return .{
            .stream = stream,
            .allocator = allocator,
            .buffer = .empty,
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
        }

        if (self.buffer.items.len == 0) return null;

        const parsed = try parseRequest(self.allocator, self.buffer.items);
        return parsed;
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
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };

        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("result");
        try std.json.stringify(result, .{}, &out.writer);
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

        const json = try out.toOwnedSlice();
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
