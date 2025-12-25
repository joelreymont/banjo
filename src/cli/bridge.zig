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

/// Content block types in assistant messages
pub const ContentBlockType = enum {
    text,
    tool_use,
    tool_result,
    image,

    pub fn fromString(s: []const u8) ?ContentBlockType {
        const map = std.StaticStringMap(ContentBlockType).initComptime(.{
            .{ "text", .text },
            .{ "tool_use", .tool_use },
            .{ "tool_result", .tool_result },
            .{ "image", .image },
        });
        return map.get(s);
    }
};

/// System message subtypes
pub const SystemSubtype = enum {
    init,
    auth_required,
    hook_response,

    pub fn fromString(s: []const u8) ?SystemSubtype {
        const map = std.StaticStringMap(SystemSubtype).initComptime(.{
            .{ "init", .init },
            .{ "auth_required", .auth_required },
            .{ "hook_response", .hook_response },
        });
        return map.get(s);
    }
};

/// Stream JSON input format for sending messages to Claude CLI
pub const StreamInput = struct {
    type: []const u8,
    message: Message,

    pub const Message = struct {
        role: []const u8,
        content: []const u8,
    };

    pub fn userPrompt(content: []const u8) StreamInput {
        return .{
            .type = "user",
            .message = .{ .role = "user", .content = content },
        };
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
    /// Uses manual traversal to avoid allocations (no parseFromValue)
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

        // For assistant messages, content is nested in message.content[]
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
                const block_type = ContentBlockType.fromString(item_type.string) orelse continue;
                if (block_type != .text) continue;
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
    /// Uses manual traversal to avoid allocations
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
            const block_type = ContentBlockType.fromString(item_type.string) orelse continue;
            if (block_type != .tool_use) continue;
            // Found tool_use, get the name
            const name = item.object.get("name") orelse continue;
            if (name == .string) return name.string;
        }
        return null;
    }

    /// Get the tool use ID from a tool_use message
    pub fn getToolId(self: *const StreamMessage) ?[]const u8 {
        if (self.type != .assistant) return null;
        const message = self.raw.object.get("message") orelse return null;
        if (message != .object) return null;
        const content = message.object.get("content") orelse return null;
        if (content != .array) return null;
        for (content.array.items) |item| {
            if (item != .object) continue;
            const item_type = item.object.get("type") orelse continue;
            if (item_type != .string) continue;
            const block_type = ContentBlockType.fromString(item_type.string) orelse continue;
            if (block_type != .tool_use) continue;
            // Found tool_use, get the id
            const id = item.object.get("id") orelse continue;
            if (id == .string) return id.string;
        }
        return null;
    }

    /// Get stop reason from result message
    pub fn getStopReason(self: *const StreamMessage) ?[]const u8 {
        if (self.type != .result) return null;
        const subtype_val = self.raw.object.get("subtype") orelse return null;
        if (subtype_val == .string) return subtype_val.string;
        return null;
    }

    /// Get system subtype as enum
    pub fn getSystemSubtype(self: *const StreamMessage) ?SystemSubtype {
        if (self.type != .system) return null;
        const subtype_str = self.subtype orelse return null;
        return SystemSubtype.fromString(subtype_str);
    }

    /// Get text delta from stream event
    pub fn getStreamTextDelta(self: *const StreamMessage) ?[]const u8 {
        const delta = self.getStreamDelta() orelse return null;
        return delta.text;
    }

    /// Get thinking delta from stream event
    pub fn getStreamThinkingDelta(self: *const StreamMessage) ?[]const u8 {
        const delta = self.getStreamDelta() orelse return null;
        return delta.thinking;
    }

    /// CLI init message structure
    pub const InitMessage = struct {
        session_id: ?[]const u8 = null,
        model: ?[]const u8 = null,
        slash_commands: ?[]const []const u8 = null,
        tools: ?[]const []const u8 = null,
    };

    /// Parse system/init message
    pub fn getInitInfo(self: *const StreamMessage) ?InitMessage {
        if (self.type != .system) return null;
        if (self.getSystemSubtype()) |subtype| {
            if (subtype != .init) return null;
        } else return null;

        const parsed = std.json.parseFromValue(InitMessage, self.arena.child_allocator, self.raw, .{
            .ignore_unknown_fields = true,
        }) catch return null;

        return parsed.value;
    }

    /// Stream event structure from Claude CLI
    pub const StreamEvent = struct {
        event: Event,

        pub const Event = struct {
            type: EventType,
            delta: ?Delta = null,

            pub const EventType = enum {
                content_block_delta,
                content_block_start,
                content_block_stop,
                message_start,
                message_delta,
                message_stop,
            };

            pub const Delta = struct {
                type: DeltaType,
                text: ?[]const u8 = null,
                thinking: ?[]const u8 = null,

                pub const DeltaType = enum {
                    text_delta,
                    thinking_delta,
                    input_json_delta,
                };
            };
        };
    };

    /// Get stream event data (text or thinking delta)
    pub fn getStreamDelta(self: *const StreamMessage) ?struct { text: ?[]const u8, thinking: ?[]const u8 } {
        if (self.type != .stream_event) return null;

        const parsed = std.json.parseFromValue(StreamEvent, self.arena.child_allocator, self.raw, .{
            .ignore_unknown_fields = true,
        }) catch return null;

        if (parsed.value.event.type != .content_block_delta) return null;

        const delta = parsed.value.event.delta orelse return null;
        return switch (delta.type) {
            .text_delta => .{ .text = delta.text, .thinking = null },
            .thinking_delta => .{ .text = null, .thinking = delta.thinking },
            .input_json_delta => null,
        };
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

    /// Find claude binary - check env var and common locations
    fn findClaudeBinary() []const u8 {
        // Check CLAUDE_CODE_EXECUTABLE env var first
        if (std.posix.getenv("CLAUDE_CODE_EXECUTABLE")) |path| {
            return path;
        }
        // Common installation locations
        const paths = [_][]const u8{
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        };
        for (paths) |path| {
            std.fs.accessAbsolute(path, .{}) catch continue;
            return path;
        }
        // Fall back to PATH lookup
        return "claude";
    }

    /// Start Claude CLI process
    pub fn start(self: *Bridge, opts: StartOptions) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        const claude_path = findClaudeBinary();
        log.info("Using claude binary: {s}", .{claude_path});
        try args.append(self.allocator, claude_path);
        try args.append(self.allocator, "-p");
        try args.append(self.allocator, "--verbose"); // Required with -p and stream-json
        try args.append(self.allocator, "--input-format");
        try args.append(self.allocator, "stream-json");
        try args.append(self.allocator, "--output-format");
        try args.append(self.allocator, "stream-json");

        if (opts.resume_session_id) |sid| {
            try args.append(self.allocator, "--resume");
            try args.append(self.allocator, sid);
        } else if (opts.continue_last) {
            try args.append(self.allocator, "--continue");
        }

        if (opts.permission_mode) |mode| {
            try args.append(self.allocator, "--permission-mode");
            try args.append(self.allocator, mode);
        }

        if (opts.mcp_config) |config| {
            try args.append(self.allocator, "--mcp-config");
            try args.append(self.allocator, config);
        }

        if (opts.model) |model| {
            try args.append(self.allocator, "--model");
            try args.append(self.allocator, model);
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
        continue_last: bool = false, // Use --continue to resume last session
        permission_mode: ?[]const u8 = null,
        mcp_config: ?[]const u8 = null,
        model: ?[]const u8 = null,
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

        const input = StreamInput.userPrompt(prompt);

        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.write(input) catch |err| {
            log.err("Failed to serialize prompt: {}", .{err});
            return error.SerializationFailed;
        };
        try out.writer.writeByte('\n');

        const data = try out.toOwnedSlice();
        defer self.allocator.free(data);

        log.debug("Sending to CLI stdin: {s}", .{data});
        try stdin.writeAll(data);
    }

    /// Read next message from CLI stdout
    pub fn readMessage(self: *Bridge) !?StreamMessage {
        const proc = self.process orelse return error.NotStarted;
        const stdout = proc.stdout orelse return error.NoStdout;

        var read_buf: [64 * 1024]u8 = undefined;
        var file_reader = stdout.reader(&read_buf);
        const reader = &file_reader.interface;

        log.debug("Waiting for CLI stdout...", .{});
        const line = reader.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => {
                log.debug("CLI read failed", .{});
                return null;
            },
            error.StreamTooLong => return error.LineTooLong,
        } orelse {
            log.debug("CLI returned null (EOF or empty)", .{});
            return null;
        };

        if (line.len == 0) {
            log.debug("CLI returned empty line", .{});
            return null;
        }

        log.debug("CLI stdout: {s}", .{line});

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

    const msg = StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed.value,
        .arena = arena,
    };

    try testing.expectEqualStrings("Hello", msg.getContent().?);
    try testing.expect(!msg.isToolUse());
}

// =============================================================================
// Property Tests for Message Parsing
// =============================================================================

const quickcheck = @import("../util/quickcheck.zig");

/// Build a test message JSON value
fn buildTestMessage(
    allocator: std.mem.Allocator,
    msg_type: MessageType,
    content_type: enum { text, tool_use, image, none },
    include_subtype: bool,
) !std.json.Value {
    var root = std.json.ObjectMap.init(allocator);
    errdefer root.deinit();

    try root.put("type", .{ .string = @tagName(msg_type) });

    if (include_subtype) {
        try root.put("subtype", .{ .string = "test_subtype" });
    }

    if (msg_type == .system) {
        if (content_type != .none) {
            try root.put("content", .{ .string = "system_content" });
        }
    } else if (msg_type == .assistant) {
        var message_obj = std.json.ObjectMap.init(allocator);
        errdefer message_obj.deinit();

        var content_array = std.json.Array.init(allocator);
        errdefer content_array.deinit();

        if (content_type == .text) {
            var text_block = std.json.ObjectMap.init(allocator);
            errdefer text_block.deinit();
            try text_block.put("type", .{ .string = "text" });
            try text_block.put("text", .{ .string = "assistant_text" });
            try content_array.append(.{ .object = text_block });
        } else if (content_type == .tool_use) {
            var tool_block = std.json.ObjectMap.init(allocator);
            errdefer tool_block.deinit();
            try tool_block.put("type", .{ .string = "tool_use" });
            try tool_block.put("name", .{ .string = "default_tool" });
            try tool_block.put("id", .{ .string = "toolu_default" });
            try content_array.append(.{ .object = tool_block });
        } else if (content_type == .image) {
            var img_block = std.json.ObjectMap.init(allocator);
            errdefer img_block.deinit();
            try img_block.put("type", .{ .string = "image" });
            try content_array.append(.{ .object = img_block });
        }

        try message_obj.put("content", .{ .array = content_array });
        try root.put("message", .{ .object = message_obj });
    } else if (msg_type == .result) {
        if (include_subtype) {
            try root.put("subtype", .{ .string = "end_turn" });
        }
    }

    return .{ .object = root };
}

fn freeTestMessage(allocator: std.mem.Allocator, val: *std.json.Value) void {
    _ = allocator;
    // Free nested structures
    if (val.object.get("message")) |msg| {
        if (msg.object.get("content")) |content| {
            for (content.array.items) |*item| {
                item.object.deinit();
            }
            var arr = content.array;
            arr.deinit();
        }
        var msg_obj = msg.object;
        msg_obj.deinit();
    }
    val.object.deinit();
}

test "property: MessageType.fromString covers all variants" {
    // All known types should parse correctly
    const known_types = [_]struct { str: []const u8, expected: MessageType }{
        .{ .str = "system", .expected = .system },
        .{ .str = "assistant", .expected = .assistant },
        .{ .str = "user", .expected = .user },
        .{ .str = "result", .expected = .result },
        .{ .str = "stream_event", .expected = .stream_event },
    };

    for (known_types) |t| {
        try testing.expectEqual(t.expected, MessageType.fromString(t.str));
    }

    // Unknown strings should return .unknown
    try quickcheck.check(struct {
        fn prop(args: struct { byte1: u8, byte2: u8, byte3: u8 }) bool {
            // Build a random string that's unlikely to match known types
            const random_str = [_]u8{ args.byte1, args.byte2, args.byte3 };
            const result = MessageType.fromString(&random_str);
            // Most random 3-byte strings should be unknown
            // (unless they happen to be "user" which is 4 chars, so safe)
            return result == .unknown or
                std.mem.eql(u8, &random_str, "sys") or
                std.mem.eql(u8, &random_str, "use") or
                std.mem.eql(u8, &random_str, "res");
        }
    }.prop, .{});
}

test "property: getToolName/getToolId extraction preserves input values" {
    // Property: for any tool name and id, extraction returns the original values
    try quickcheck.check(struct {
        fn prop(args: struct { name_seed: u32, id_seed: u32 }) bool {
            // Generate deterministic "random" names from seeds
            var name_buf: [16]u8 = undefined;
            var id_buf: [20]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "Tool_{x}", .{args.name_seed}) catch return false;
            const id = std.fmt.bufPrint(&id_buf, "toolu_{x}", .{args.id_seed}) catch return false;

            // Build JSON with these values
            var json_buf: [256]u8 = undefined;
            const json = std.fmt.bufPrint(&json_buf,
                \\{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"{s}","id":"{s}"}}]}}}}
            , .{ name, id }) catch return false;

            // Parse and extract
            const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch return false;
            defer parsed.deinit();

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const msg = StreamMessage{ .type = .assistant, .subtype = null, .raw = parsed.value, .arena = arena };

            // Property: extracted values equal input values
            const extracted_name = msg.getToolName() orelse return false;
            const extracted_id = msg.getToolId() orelse return false;
            return std.mem.eql(u8, extracted_name, name) and std.mem.eql(u8, extracted_id, id);
        }
    }.prop, .{});
}

test "property: getContent extraction preserves input text" {
    try quickcheck.check(struct {
        fn prop(args: struct { text_seed: u32 }) bool {
            // Generate deterministic text from seed (avoid special chars that break JSON)
            var text_buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "Message_{x}", .{args.text_seed}) catch return false;

            // Build JSON
            var json_buf: [256]u8 = undefined;
            const json = std.fmt.bufPrint(&json_buf,
                \\{{"type":"assistant","message":{{"content":[{{"type":"text","text":"{s}"}}]}}}}
            , .{text}) catch return false;

            // Parse and extract
            const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch return false;
            defer parsed.deinit();

            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const msg = StreamMessage{ .type = .assistant, .subtype = null, .raw = parsed.value, .arena = arena };

            // Property: extracted text equals input text
            const extracted = msg.getContent() orelse return false;
            return std.mem.eql(u8, extracted, text);
        }
    }.prop, .{});
}

test "getToolName/getToolId return null for non-tool messages" {
    // This is exhaustive, not property-based - just test the specific cases
    const cases = [_][]const u8{
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}
        ,
        \\{"type":"system","content":"hello"}
        ,
        \\{"type":"result","subtype":"success"}
    };
    const types = [_]MessageType{ .assistant, .system, .result };

    for (cases, types) |json, msg_type| {
        const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch continue;
        defer parsed.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const msg = StreamMessage{ .type = msg_type, .subtype = null, .raw = parsed.value, .arena = arena };
        try testing.expect(msg.getToolName() == null);
        try testing.expect(msg.getToolId() == null);
    }
}

test "property: getStopReason only works for result type" {
    const types = [_]MessageType{ .system, .assistant, .user, .result, .stream_event };

    for (types) |msg_type| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var json_val = try buildTestMessage(alloc, msg_type, .none, true);
        _ = &json_val;

        const msg = StreamMessage{
            .type = msg_type,
            .subtype = "end_turn",
            .raw = json_val,
            .arena = arena,
        };

        const reason = msg.getStopReason();
        if (msg_type == .result) {
            try testing.expect(reason != null);
        } else {
            try testing.expect(reason == null);
        }
    }
}

test "property: system messages extract content from content or message field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test content field
    var json1 = try buildTestMessage(alloc, .system, .text, false);
    _ = &json1;
    const msg1 = StreamMessage{
        .type = .system,
        .subtype = null,
        .raw = json1,
        .arena = arena,
    };
    try testing.expectEqualStrings("system_content", msg1.getContent().?);

    // Test message field fallback
    var root2 = std.json.ObjectMap.init(alloc);
    try root2.put("type", .{ .string = "system" });
    try root2.put("message", .{ .string = "fallback_message" });
    const json2 = std.json.Value{ .object = root2 };

    const msg2 = StreamMessage{
        .type = .system,
        .subtype = null,
        .raw = json2,
        .arena = arena,
    };
    try testing.expectEqualStrings("fallback_message", msg2.getContent().?);
}
