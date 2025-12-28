const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.codex_bridge);
const executable = @import("executable.zig");

pub const CodexMessage = struct {
    event_type: EventType,
    thread_id: ?[]const u8 = null,
    item: ?Item = null,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CodexMessage) void {
        self.arena.deinit();
    }

    pub const EventType = enum {
        thread_started,
        turn_started,
        item_started,
        item_completed,
        turn_completed,
        unknown,
    };

    pub const Item = struct {
        id: []const u8,
        type: []const u8,
        text: ?[]const u8 = null,
        command: ?[]const u8 = null,
        aggregated_output: ?[]const u8 = null,
        exit_code: ?i64 = null,
        status: ?[]const u8 = null,
    };

    pub const ToolCall = struct {
        id: []const u8,
        command: []const u8,
    };

    pub const ToolResult = struct {
        id: []const u8,
        content: ?[]const u8 = null,
        exit_code: ?i64 = null,
    };

    pub fn getText(self: *const CodexMessage) ?[]const u8 {
        if (self.event_type != .item_completed) return null;
        const item = self.item orelse return null;
        if (!std.mem.eql(u8, item.type, "agent_message")) return null;
        return item.text;
    }

    pub fn getThought(self: *const CodexMessage) ?[]const u8 {
        if (self.event_type != .item_completed) return null;
        const item = self.item orelse return null;
        if (!std.mem.eql(u8, item.type, "reasoning")) return null;
        return item.text;
    }

    pub fn getToolCall(self: *const CodexMessage) ?ToolCall {
        if (self.event_type != .item_started) return null;
        const item = self.item orelse return null;
        const command = item.command orelse return null;
        return .{ .id = item.id, .command = command };
    }

    pub fn getToolResult(self: *const CodexMessage) ?ToolResult {
        if (self.event_type != .item_completed) return null;
        const item = self.item orelse return null;
        if (item.command == null and item.aggregated_output == null and item.exit_code == null) return null;
        return .{
            .id = item.id,
            .content = item.aggregated_output,
            .exit_code = item.exit_code,
        };
    }

    pub fn getSessionId(self: *const CodexMessage) ?[]const u8 {
        if (self.event_type != .thread_started) return null;
        return self.thread_id;
    }

    pub fn isTurnCompleted(self: *const CodexMessage) bool {
        return self.event_type == .turn_completed;
    }
};

const Envelope = struct {
    type: []const u8,
    thread_id: ?[]const u8 = null,
    item: ?CodexMessage.Item = null,
};

const event_type_map = std.StaticStringMap(CodexMessage.EventType).initComptime(.{
    .{ "thread.started", .thread_started },
    .{ "turn.started", .turn_started },
    .{ "item.started", .item_started },
    .{ "item.completed", .item_completed },
    .{ "turn.completed", .turn_completed },
});

fn mapEventType(event_type: []const u8) CodexMessage.EventType {
    return event_type_map.get(event_type) orelse .unknown;
}

pub const CodexBridge = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    cwd: []const u8,
    stdout_reader: ?std.fs.File.Reader = null,
    stdout_buf: [64 * 1024]u8 = undefined,

    pub fn init(allocator: Allocator, cwd: []const u8) CodexBridge {
        return .{
            .allocator = allocator,
            .cwd = cwd,
        };
    }

    pub fn deinit(self: *CodexBridge) void {
        self.stop();
    }

    fn findCodexBinary() []const u8 {
        return executable.choose("CODEX_EXECUTABLE", "codex", codex_paths[0..]);
    }

    const codex_paths = [_][]const u8{
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
    };

    pub fn isAvailable() bool {
        return executable.isAvailable("CODEX_EXECUTABLE", "codex", codex_paths[0..]);
    }

    pub const StartOptions = struct {
        resume_session_id: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };

    pub fn start(self: *CodexBridge, opts: StartOptions) !void {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        const codex_path = findCodexBinary();
        log.info("Using codex binary: {s}", .{codex_path});

        try args.append(self.allocator, codex_path);
        try args.append(self.allocator, "exec");
        try args.append(self.allocator, "--json");

        if (opts.model) |model| {
            try args.append(self.allocator, "--model");
            try args.append(self.allocator, model);
        }

        if (opts.resume_session_id) |sid| {
            try args.append(self.allocator, "resume");
            try args.append(self.allocator, sid);
        }

        try args.append(self.allocator, "-");

        var child = std.process.Child.init(args.items, self.allocator);
        child.cwd = self.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
        self.process = child;
        if (self.process.?.stdout) |stdout| {
            self.stdout_reader = stdout.reader(&self.stdout_buf);
        } else {
            self.stdout_reader = null;
        }
    }

    pub fn stop(self: *CodexBridge) void {
        if (self.process) |*proc| {
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
            self.stdout_reader = null;
            log.info("Stopped Codex", .{});
        }
    }

    pub fn sendPrompt(self: *CodexBridge, prompt: []const u8) !void {
        const proc = self.process orelse return error.NotStarted;
        const stdin = proc.stdin orelse return error.NoStdin;

        try stdin.writeAll(prompt);
        try stdin.writeAll("\n");
        // Codex expects EOF for non-interactive exec prompts.
        stdin.close();
    }

    pub fn readMessage(self: *CodexBridge) !?CodexMessage {
        _ = self.process orelse return error.NotStarted;
        const reader = if (self.stdout_reader) |*stdout_reader| &stdout_reader.interface else return error.NoStdout;

        const line = reader.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => return null,
            error.StreamTooLong => return error.LineTooLong,
        } orelse return null;

        if (line.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), line, .{
            .ignore_unknown_fields = true,
        });

        return CodexMessage{
            .event_type = mapEventType(parsed.value.type),
            .thread_id = parsed.value.thread_id,
            .item = parsed.value.item,
            .arena = arena,
        };
    }
};

// Tests
const testing = std.testing;

test "CodexMessage agent_message parsing" {
    const json =
        \\{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Hello"}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    const msg = CodexMessage{
        .event_type = mapEventType(parsed.value.type),
        .thread_id = parsed.value.thread_id,
        .item = parsed.value.item,
        .arena = arena,
    };
    try testing.expectEqualStrings("Hello", msg.getText().?);
}

test "CodexMessage tool call parsing" {
    const json =
        \\{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc ls","status":"in_progress"}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    const msg = CodexMessage{
        .event_type = mapEventType(parsed.value.type),
        .thread_id = parsed.value.thread_id,
        .item = parsed.value.item,
        .arena = arena,
    };
    const tool = msg.getToolCall().?;
    try testing.expectEqualStrings("item_2", tool.id);
    try testing.expectEqualStrings("/bin/zsh -lc ls", tool.command);
}

test "CodexMessage tool result parsing" {
    const json =
        \\{"type":"item.completed","item":{"id":"item_2","type":"command_execution","aggregated_output":"ok","exit_code":0,"status":"completed"}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    const msg = CodexMessage{
        .event_type = mapEventType(parsed.value.type),
        .thread_id = parsed.value.thread_id,
        .item = parsed.value.item,
        .arena = arena,
    };
    const tool = msg.getToolResult().?;
    try testing.expectEqualStrings("item_2", tool.id);
    try testing.expectEqualStrings("ok", tool.content.?);
    try testing.expectEqual(@as(i64, 0), tool.exit_code.?);
}

test "CodexMessage reasoning maps to thought" {
    const json =
        \\{"type":"item.completed","item":{"id":"item_3","type":"reasoning","text":"Thinking"}} 
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(Envelope, arena.allocator(), json, .{
        .ignore_unknown_fields = true,
    });

    const msg = CodexMessage{
        .event_type = mapEventType(parsed.value.type),
        .thread_id = parsed.value.thread_id,
        .item = parsed.value.item,
        .arena = arena,
    };
    try testing.expectEqualStrings("Thinking", msg.getThought().?);
}
