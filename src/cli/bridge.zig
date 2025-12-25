const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.cli_bridge);

/// Stream JSON message types from Claude CLI
pub const MessageType = enum {
    system,
    assistant,
    user,
    result,
    stream_event,
    unknown,

    pub fn fromString(s: []const u8) MessageType {
        const map = std.StaticStringMap(MessageType).initComptime(.{
            .{ "system", .system },
            .{ "assistant", .assistant },
            .{ "user", .user },
            .{ "result", .result },
            .{ "stream_event", .stream_event },
        });
        return map.get(s) orelse .unknown;
    }
};

/// Parsed stream message
pub const StreamMessage = struct {
    type: MessageType,
    subtype: ?[]const u8 = null,
    raw: std.json.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *StreamMessage) void {
        self.arena.deinit();
    }

    /// Get content from message (works for assistant and system messages)
    pub fn getContent(self: *const StreamMessage) ?[]const u8 {
        // For system messages, content may be a direct string
        if (self.type == .system) {
            if (self.raw.object.get("content")) |content| {
                if (content == .string) return content.string;
            }
            if (self.raw.object.get("message")) |message| {
                if (message == .string) return message.string;
            }
        }

        // For assistant messages, content is nested
        if (self.type == .assistant) {
            const message = self.raw.object.get("message") orelse return null;
            if (message != .object) return null;
            const content = message.object.get("content") orelse return null;
            if (content != .array) return null;
            // Get first text block
            for (content.array.items) |item| {
                if (item != .object) continue;
                const item_type = item.object.get("type") orelse continue;
                if (item_type != .string) continue;
                if (!std.mem.eql(u8, item_type.string, "text")) continue;
                const text = item.object.get("text") orelse continue;
                if (text == .string) return text.string;
            }
        }

        return null;
    }

    /// Check if this is a tool use event
    pub fn isToolUse(self: *const StreamMessage) bool {
        return self.getToolName() != null;
    }

    /// Get the tool name from a tool_use message
    pub fn getToolName(self: *const StreamMessage) ?[]const u8 {
        if (self.type != .assistant) return null;
        const message = self.raw.object.get("message") orelse return null;
        if (message != .object) return null;
        const content = message.object.get("content") orelse return null;
        if (content != .array) return null;
        for (content.array.items) |item| {
            if (item != .object) continue;
            const item_type = item.object.get("type") orelse continue;
            if (item_type != .string) continue;
            if (!std.mem.eql(u8, item_type.string, "tool_use")) continue;
            // Found tool_use, get the name
            const name = item.object.get("name") orelse continue;
            if (name == .string) return name.string;
        }
        return null;
    }

    /// Get stop reason from result message
    pub fn getStopReason(self: *const StreamMessage) ?[]const u8 {
        if (self.type != .result) return null;
        const subtype = self.raw.object.get("subtype") orelse return null;
        if (subtype == .string) return subtype.string;
        return null;
    }
};

/// Claude CLI Bridge - spawns and communicates with Claude CLI
pub const Bridge = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    cwd: []const u8,
    session_id: ?[]const u8 = null,

    pub fn init(allocator: Allocator, cwd: []const u8) Bridge {
        return .{
            .allocator = allocator,
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *Bridge) void {
        self.stop();
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
    }

    /// Start Claude CLI process
    pub fn start(self: *Bridge, opts: StartOptions) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "claude");
        try args.append(self.allocator, "-p");
        try args.append(self.allocator, "--input-format");
        try args.append(self.allocator, "stream-json");
        try args.append(self.allocator, "--output-format");
        try args.append(self.allocator, "stream-json");
        try args.append(self.allocator, "--include-partial-messages");

        if (opts.resume_session_id) |sid| {
            try args.append(self.allocator, "--resume");
            try args.append(self.allocator, sid);
        }

        if (opts.permission_mode) |mode| {
            try args.append(self.allocator, "--permission-mode");
            try args.append(self.allocator, mode);
        }

        if (opts.mcp_config) |config| {
            try args.append(self.allocator, "--mcp-config");
            try args.append(self.allocator, config);
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.cwd = self.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        self.process = child;

        log.info("Started Claude CLI in {s}", .{self.cwd});
    }

    pub const StartOptions = struct {
        resume_session_id: ?[]const u8 = null,
        permission_mode: ?[]const u8 = null,
        mcp_config: ?[]const u8 = null,
    };

    /// Stop the CLI process
    pub fn stop(self: *Bridge) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
            log.info("Stopped Claude CLI", .{});
        }
    }

    /// Send a prompt to the CLI
    pub fn sendPrompt(self: *Bridge, prompt: []const u8) !void {
        const proc = self.process orelse return error.NotStarted;
        const stdin = proc.stdin orelse return error.NoStdin;

        // Stream-json input format: {"type": "user", "content": "..."}
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const w = &out.writer;

        try w.writeAll("{\"type\":\"user\",\"content\":");
        try std.json.Stringify.encodeJsonString(prompt, .{}, w);
        try w.writeAll("}\n");

        const data = try out.toOwnedSlice();
        defer self.allocator.free(data);

        try stdin.writeAll(data);
    }

    /// Read next message from CLI stdout
    pub fn readMessage(self: *Bridge) !?StreamMessage {
        const proc = self.process orelse return error.NotStarted;
        const stdout = proc.stdout orelse return error.NoStdout;

        var read_buf: [64 * 1024]u8 = undefined;
        var file_reader = stdout.reader(&read_buf);
        const reader = &file_reader.interface;

        const line = reader.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => return null,
            error.StreamTooLong => return error.LineTooLong,
        } orelse return null;

        if (line.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{});

        const msg_type = if (parsed.value.object.get("type")) |t|
            if (t == .string) MessageType.fromString(t.string) else .unknown
        else
            .unknown;

        const subtype = if (parsed.value.object.get("subtype")) |s|
            if (s == .string) s.string else null
        else
            null;

        return StreamMessage{
            .type = msg_type,
            .subtype = subtype,
            .raw = parsed.value,
            .arena = arena,
        };
    }
};

// Tests
const testing = std.testing;

test "MessageType.fromString" {
    try testing.expectEqual(MessageType.system, MessageType.fromString("system"));
    try testing.expectEqual(MessageType.assistant, MessageType.fromString("assistant"));
    try testing.expectEqual(MessageType.result, MessageType.fromString("result"));
    try testing.expectEqual(MessageType.unknown, MessageType.fromString("invalid"));
}

test "StreamMessage parsing" {
    const json =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});

    var msg = StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed.value,
        .arena = undefined, // Not used in this test
    };

    try testing.expectEqualStrings("Hello", msg.getContent().?);
    try testing.expect(!msg.isToolUse());
}
