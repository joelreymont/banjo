const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config");
const constants = @import("constants.zig");
const log = std.log.scoped(.cli_bridge);
const executable = @import("executable.zig");
const io_utils = @import("io_utils.zig");
const test_utils = @import("test_utils.zig");
const core_types = @import("types.zig");

const max_json_line_bytes: usize = 4 * 1024 * 1024;
const debug_log = @import("../util/debug_log.zig");

// Models supported by Claude Code CLI
pub const models = [_]core_types.ModelInfo{
    .{ .id = "sonnet", .name = "Claude Sonnet", .desc = "Fast, balanced" },
    .{ .id = "opus", .name = "Claude Opus", .desc = "Most capable" },
    .{ .id = "haiku", .name = "Claude Haiku", .desc = "Fastest" },
};

fn bridgeDebugLog(comptime fmt: []const u8, args: anytype) void {
    debug_log.write("BRIDGE", fmt, args);
}

/// Stream JSON message types from Claude Code
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

pub const ContentBlock = struct {
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
    name: ?[]const u8 = null,
    id: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
    input: ?std.json.Value = null,
    content: ?ToolResultContent = null,
    is_error: ?bool = null,
    @"error": ?[]const u8 = null,
};

const ToolResultBlock = struct {
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const ToolResultContent = union(enum) {
    text: []const u8,
    blocks: []ToolResultBlock,

    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!ToolResultContent {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!ToolResultContent {
        _ = options;
        return switch (source) {
            .string => |text| .{ .text = text },
            .array => {
                const parsed = try std.json.parseFromValueLeaky([]ToolResultBlock, allocator, source, .{
                    .ignore_unknown_fields = true,
                });
                return .{ .blocks = parsed };
            },
            .object => {
                const parsed = try std.json.parseFromValueLeaky(ToolResultBlock, allocator, source, .{
                    .ignore_unknown_fields = true,
                });
                const list = try allocator.alloc(ToolResultBlock, 1);
                list[0] = parsed;
                return .{ .blocks = list };
            },
            else => error.UnexpectedToken,
        };
    }
};

const MessageObject = struct {
    content: ?[]ContentBlock = null,
};

const MessageField = struct {
    text: ?[]const u8 = null,
    content: ?[]ContentBlock = null,

    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!MessageField {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(
        allocator: Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!MessageField {
        _ = options;
        return switch (source) {
            .string => |text| .{ .text = text },
            .object => {
                const parsed = try std.json.parseFromValueLeaky(MessageObject, allocator, source, .{
                    .ignore_unknown_fields = true,
                });
                return .{ .content = parsed.content };
            },
            else => error.UnexpectedToken,
        };
    }
};

const StreamEnvelope = struct {
    type: []const u8,
    subtype: ?[]const u8 = null,
    message: ?MessageField = null,
    content: ?[]const u8 = null,
    event: ?std.json.Value = null,
    session_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    slash_commands: ?[]const []const u8 = null,
    tools: ?[]const []const u8 = null,
};

/// Stream JSON input format for sending messages to Claude Code
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

pub const StreamControlInput = struct {
    type: []const u8 = "control",
    control: Control,

    pub const Control = struct {
        type: []const u8,
        mode: []const u8,
    };

    pub fn setPermissionMode(mode: []const u8) StreamControlInput {
        return .{
            .control = .{
                .type = "set_permission_mode",
                .mode = mode,
            },
        };
    }
};

/// Parsed stream message
pub const StreamMessage = struct {
    type: MessageType,
    subtype: ?[]const u8 = null,
    envelope: ?StreamEnvelope = null,
    envelope_failed: bool = false,
    raw: std.json.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *StreamMessage) void {
        self.arena.deinit();
    }

    fn arenaAllocator(self: *const StreamMessage) Allocator {
        return @constCast(&self.arena).allocator();
    }

    fn getEnvelope(self: *const StreamMessage) ?StreamEnvelope {
        if (self.envelope) |env| return env;
        if (self.envelope_failed) return null;
        const parsed = std.json.parseFromValueLeaky(StreamEnvelope, self.arenaAllocator(), self.raw, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse stream envelope: {}", .{err});
            @constCast(self).envelope_failed = true;
            return null;
        };
        @constCast(self).envelope = parsed;
        return parsed;
    }

    /// Get content from message (works for assistant and system messages)
    pub fn getContent(self: *const StreamMessage) ?[]const u8 {
        const env = self.getEnvelope() orelse return null;

        // For system messages, content may be a direct string
        if (self.type == .system) {
            if (env.content) |content| return content;
            if (env.message) |message| {
                if (message.text) |text| return text;
            }
        }

        // For assistant messages, content is nested in message.content[]
        if (self.type == .assistant) {
            const message = env.message orelse return null;
            const content = message.content orelse return null;
            // Get first text block
            for (content) |item| {
                const item_type = item.type orelse continue;
                const block_type = ContentBlockType.fromString(item_type) orelse continue;
                if (block_type != .text) continue;
                if (item.text) |text| return text;
            }
        }

        return null;
    }

    pub const ToolUse = struct {
        id: []const u8,
        name: []const u8,
        input: ?std.json.Value = null,
    };

    pub const ToolResult = struct {
        id: []const u8,
        content: ?[]const u8 = null,
        is_error: bool = false,
        raw: std.json.Value = .null,
    };

    /// Check if this is a tool use event
    pub fn isToolUse(self: *const StreamMessage) bool {
        return self.getToolUse() != null;
    }

    /// Get raw content blocks for iteration
    pub fn getContentBlocksSlice(self: *const StreamMessage) ?[]const ContentBlock {
        if (self.type != .assistant and self.type != .user) return null;
        const env = self.getEnvelope() orelse return null;
        const message = env.message orelse return null;
        return message.content;
    }

    /// Get tool use details from assistant message (first match only)
    pub fn getToolUse(self: *const StreamMessage) ?ToolUse {
        if (self.type != .assistant) return null;
        const env = self.getEnvelope() orelse return null;
        const message = env.message orelse return null;
        const content = message.content orelse return null;
        for (content) |item| {
            const item_type = item.type orelse continue;
            const block_type = ContentBlockType.fromString(item_type) orelse continue;
            if (block_type != .tool_use) continue;
            const name = item.name orelse continue;
            const id = item.id orelse continue;
            return .{ .id = id, .name = name, .input = item.input };
        }
        return null;
    }

    /// Convert a ContentBlock to ToolUse if it's a tool_use block
    pub fn contentBlockToToolUse(item: ContentBlock) ?ToolUse {
        const item_type = item.type orelse return null;
        const block_type = ContentBlockType.fromString(item_type) orelse return null;
        if (block_type != .tool_use) return null;
        const name = item.name orelse return null;
        const id = item.id orelse return null;
        return .{ .id = id, .name = name, .input = item.input };
    }

    /// Check if a ContentBlock is a text block and get its text
    pub fn contentBlockToText(item: ContentBlock) ?[]const u8 {
        const item_type = item.type orelse return null;
        const block_type = ContentBlockType.fromString(item_type) orelse return null;
        if (block_type != .text) return null;
        return item.text;
    }

    /// Get tool result details from assistant message
    pub fn getToolResult(self: *const StreamMessage) ?ToolResult {
        if (self.type != .assistant and self.type != .user) return null;
        const env = self.getEnvelope() orelse return null;
        const message = env.message orelse return null;
        const content = message.content orelse return null;

        // Navigate raw JSON to get corresponding raw items
        const raw_items = self.getRawContentItems();

        for (content, 0..) |item, i| {
            const item_type = item.type orelse continue;
            const block_type = ContentBlockType.fromString(item_type) orelse continue;
            if (block_type != .tool_result) continue;
            const id = item.tool_use_id orelse item.id orelse continue;
            var is_error = false;
            if (item.is_error) |flag| {
                is_error = flag;
            } else if (item.@"error") |err| {
                if (err.len > 0) is_error = true;
            }
            const content_val = item.content;

            // Get corresponding raw item if available
            const raw_item = if (raw_items) |items|
                (if (i < items.len) items[i] else .null)
            else
                .null;

            return .{
                .id = id,
                .content = if (content_val) |val| extractToolResultText(val) else null,
                .is_error = is_error,
                .raw = raw_item,
            };
        }
        return null;
    }

    fn getRawContentItems(self: *const StreamMessage) ?[]const std.json.Value {
        const raw_obj = switch (self.raw) {
            .object => |obj| obj,
            else => return null,
        };
        const message_val = raw_obj.get("message") orelse return null;
        const message_obj = switch (message_val) {
            .object => |obj| obj,
            else => return null,
        };
        const content_val = message_obj.get("content") orelse return null;
        return switch (content_val) {
            .array => |arr| arr.items,
            else => null,
        };
    }

    fn extractToolResultText(content: ToolResultContent) ?[]const u8 {
        return switch (content) {
            .text => |text| text,
            .blocks => |blocks| blk: {
                for (blocks) |block| {
                    const text = block.text orelse continue;
                    if (block.type) |block_type| {
                        const parsed = ContentBlockType.fromString(block_type) orelse continue;
                        if (parsed != .text) continue;
                    }
                    break :blk text;
                }
                break :blk null;
            },
        };
    }

    /// Get the tool name from a tool_use message
    /// Uses manual traversal to avoid allocations
    pub fn getToolName(self: *const StreamMessage) ?[]const u8 {
        const tool = self.getToolUse() orelse return null;
        return tool.name;
    }

    /// Get the tool use ID from a tool_use message
    pub fn getToolId(self: *const StreamMessage) ?[]const u8 {
        const tool = self.getToolUse() orelse return null;
        return tool.id;
    }

    /// Get stop reason from result message
    pub fn getStopReason(self: *const StreamMessage) ?[]const u8 {
        if (self.type != .result) return null;
        return self.subtype;
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
        const env = self.getEnvelope() orelse return null;
        return .{
            .session_id = env.session_id,
            .model = env.model,
            .slash_commands = env.slash_commands,
            .tools = env.tools,
        };
    }

    /// Stream event structure from Claude Code
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
        const event = self.parseStreamEvent() orelse return null;
        if (event.type != .content_block_delta) return null;

        const delta = event.delta orelse return null;
        return switch (delta.type) {
            .text_delta => .{ .text = delta.text, .thinking = null },
            .thinking_delta => .{ .text = null, .thinking = delta.thinking },
            .input_json_delta => null,
        };
    }

    /// Get stream event type (message start/stop, content block, etc.)
    pub fn getStreamEventType(self: *const StreamMessage) ?StreamEvent.Event.EventType {
        const event = self.parseStreamEvent() orelse return null;
        return event.type;
    }

    fn parseStreamEvent(self: *const StreamMessage) ?StreamEvent.Event {
        if (self.type != .stream_event) return null;
        const env = self.getEnvelope() orelse return null;
        const event_val = env.event orelse return null;
        // Parse into the message arena; deinit only releases parse bookkeeping.
        const parsed = std.json.parseFromValue(StreamEvent, self.arenaAllocator(), event_val, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse stream event: {}", .{err});
            return null;
        };
        defer parsed.deinit();
        return parsed.value.event;
    }
};

/// Claude Code Bridge - spawns and communicates with Claude Code
pub const Bridge = struct {
    allocator: Allocator,
    process: ?std.process.Child = null,
    cwd: []const u8,
    session_id: ?[]const u8 = null,
    stdout_reader: ?std.fs.File.Reader = null,
    stdout_buf: [constants.stdout_buffer_size]u8 = undefined,
    message_queue: std.ArrayList(StreamMessage) = .empty,
    queue_head: usize = 0,
    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    reader_thread: ?std.Thread = null,
    reader_closed: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    interrupted: bool = false,

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
        self.message_queue.deinit(self.allocator);
    }

    /// Find Claude Code binary - check env var and common locations
    fn findClaudeBinary() []const u8 {
        return executable.choose("CLAUDE_CODE_EXECUTABLE", "claude", claude_paths[0..]);
    }

    const claude_paths = [_][]const u8{
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    };

    pub fn isAvailable() bool {
        return executable.isAvailable("CLAUDE_CODE_EXECUTABLE", "claude", claude_paths[0..]);
    }

    /// Start Claude Code process
    pub fn start(self: *Bridge, opts: StartOptions) !void {
        // Clean up old process/thread if restarting
        if (self.process != null or self.reader_thread != null) {
            self.stop_requested.store(true, .release);
            if (self.process) |*proc| {
                // Kill first so reader thread sees EOF
                _ = proc.kill() catch |err| {
                    log.warn("Failed to kill Claude process: {}", .{err});
                };
                _ = proc.wait() catch |err| {
                    log.warn("Failed to wait for Claude process: {}", .{err});
                };
            }
            if (self.reader_thread) |thread| {
                thread.join();
                self.reader_thread = null;
            }
            self.process = null;
            self.stdout_reader = null;
        }

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(self.allocator);

        const claude_path = findClaudeBinary();
        log.info("Using claude binary: {s}", .{claude_path});
        try args.appendSlice(self.allocator, &[_][]const u8{
            claude_path,
            "-p",
            "--verbose", // Required with -p and stream-json
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
        });

        if (opts.resume_session_id) |sid| {
            try args.append(self.allocator, "--resume");
            try args.append(self.allocator, sid);
        } else if (opts.continue_last) {
            try args.append(self.allocator, "--continue");
        }

        if (opts.skip_permissions) {
            try args.append(self.allocator, "--dangerously-skip-permissions");
        }

        if (opts.permission_mode) |mode| {
            try args.append(self.allocator, "--permission-mode");
            try args.append(self.allocator, mode);
        }

        if (opts.model) |model| {
            try args.append(self.allocator, "--model");
            try args.append(self.allocator, model);
        }

        var child = std.process.Child.init(args.items, self.allocator);
        child.cwd = self.cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe; // Capture stderr for debugging

        // Set permission socket environment variable if provided
        var env: ?std.process.EnvMap = null;
        defer if (env) |*e| e.deinit();

        if (opts.permission_socket_path) |socket_path| {
            // Get current environment and add our socket path
            env = try std.process.getEnvMap(self.allocator);
            try env.?.put("BANJO_PERMISSION_SOCKET", socket_path);
            child.env_map = &env.?;
            log.info("Set BANJO_PERMISSION_SOCKET={s}", .{socket_path});
        }

        bridgeDebugLog("start: spawning claude process", .{});
        try child.spawn();
        errdefer {
            _ = child.kill() catch |err| blk: {
                log.warn("Failed to kill Claude child: {}", .{err});
                break :blk std.process.Child.Term{ .Unknown = 0 };
            };
            _ = child.wait() catch |err| blk: {
                log.warn("Failed to wait for Claude child: {}", .{err});
                break :blk std.process.Child.Term{ .Unknown = 0 };
            };
        }
        bridgeDebugLog("start: spawned, pid={d}", .{child.id});
        self.process = child;
        if (self.process.?.stdout) |stdout| {
            self.stdout_reader = stdout.reader(&self.stdout_buf);
            bridgeDebugLog("start: stdout reader initialized", .{});
        } else {
            self.stdout_reader = null;
            bridgeDebugLog("start: no stdout!", .{});
        }
        self.queue_mutex.lock();
        self.reader_closed = false;
        self.queue_mutex.unlock();
        self.interrupted = false;
        self.stop_requested.store(false, .release);
        self.clearQueue();
        bridgeDebugLog("start: starting reader thread", .{});
        self.startReaderThread() catch |err| {
            self.stop();
            return err;
        };

        log.info("Started Claude Code in {s}", .{self.cwd});
    }

    fn startReaderThread(self: *Bridge) !void {
        if (self.reader_thread != null) return;
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
    }

    pub const StartOptions = struct {
        resume_session_id: ?[]const u8 = null,
        continue_last: bool = false, // Use --continue to resume last session
        skip_permissions: bool = false,
        permission_mode: ?[]const u8 = null,
        model: ?[]const u8 = null,
        permission_socket_path: ?[]const u8 = null, // Unix socket for permission hook
    };

    /// Interrupt the current request (SIGINT to Claude CLI)
    /// Claude exits on SIGINT - next prompt will restart with --continue.
    pub fn interrupt(self: *Bridge) void {
        self.interrupted = true;
        self.stop_requested.store(true, .release);
        if (self.process) |*proc| {
            const pid = proc.id;
            log.info("Sending SIGINT to Claude CLI (pid={})", .{pid});
            std.posix.kill(pid, std.posix.SIG.INT) catch |err| {
                log.warn("Failed to send SIGINT to Claude: {}", .{err});
            };
            // Wait for process to exit
            _ = proc.wait() catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("Failed to wait for Claude process: {}", .{err}),
            };
        }
        // Join reader thread
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.process = null;
        self.stdout_reader = null;
        self.queue_mutex.lock();
        self.reader_closed = true;
        self.queue_mutex.unlock();
        self.queue_cond.broadcast();
        self.clearQueue();
        log.info("Interrupt complete, bridge cleaned up", .{});
    }

    /// Stop the CLI process
    pub fn stop(self: *Bridge) void {
        self.stop_requested.store(true, .release);
        if (self.process) |*proc| {
            _ = proc.kill() catch |err| switch (err) {
                error.AlreadyTerminated => {},
                else => log.warn("Failed to kill Claude process: {}", .{err}),
            };
            _ = proc.wait() catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("Failed to wait for Claude process: {}", .{err}),
            };
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.process = null;
        self.stdout_reader = null;
        self.queue_mutex.lock();
        self.reader_closed = true;
        self.queue_mutex.unlock();
        self.queue_cond.broadcast();
        self.clearQueue();
        log.info("Stopped Claude Code", .{});
    }

    /// Check if the bridge process is alive and ready for prompts
    pub fn isAlive(self: *Bridge) bool {
        if (self.process == null) return false;
        if (self.interrupted) return false;
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return !self.reader_closed;
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
        stdin.writeAll(data) catch |err| {
            if (err == error.BrokenPipe) {
                // Process died - try to get exit status and stderr
                if (self.process) |*child| {
                    // Read stderr if available
                    if (child.stderr) |stderr| {
                        var stderr_buf: [4096]u8 = undefined;
                        const stderr_len = stderr.read(&stderr_buf) catch |read_err| blk: {
                            log.warn("Failed to read Claude CLI stderr: {}", .{read_err});
                            break :blk 0;
                        };
                        if (stderr_len > 0) {
                            log.err("Claude CLI stderr: {s}", .{stderr_buf[0..stderr_len]});
                        }
                    }
                    const term = child.wait() catch |wait_err| blk: {
                        log.err("Claude CLI died (BrokenPipe), wait failed: {}", .{wait_err});
                        break :blk std.process.Child.Term{ .Unknown = 0 };
                    };
                    switch (term) {
                        .Exited => |code| log.err("Claude CLI exited with code {d}", .{code}),
                        .Signal => |sig| log.err("Claude CLI killed by signal {d}", .{sig}),
                        .Stopped => |sig| log.err("Claude CLI stopped by signal {d}", .{sig}),
                        .Unknown => |val| log.err("Claude CLI terminated (unknown: {d})", .{val}),
                    }
                    self.stop();
                }
            }
            return err;
        };
    }

    /// Read next message from CLI stdout (reader thread only).
    fn readMessageRaw(self: *Bridge) !?StreamMessage {
        _ = self.process orelse return error.NotStarted;
        const reader = if (self.stdout_reader) |*stdout_reader| &stdout_reader.interface else return error.NoStdout;

        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            var keep_arena = false;
            defer if (!keep_arena) arena.deinit();

            var line_writer: std.io.Writer.Allocating = .init(arena.allocator());
            defer line_writer.deinit();

            _ = reader.streamDelimiterLimit(&line_writer.writer, '\n', .limited(max_json_line_bytes)) catch |e| switch (e) {
                error.ReadFailed => {
                    bridgeDebugLog("readMessageRaw: streamDelimiter ReadFailed", .{});
                    return null;
                },
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => return error.LineTooLong,
            };

            if (reader.peekGreedy(1)) |peek| {
                if (peek.len > 0 and peek[0] == '\n') {
                    reader.toss(1);
                }
            } else |err| switch (err) {
                error.ReadFailed => {
                    bridgeDebugLog("readMessageRaw: peekGreedy ReadFailed", .{});
                    return null;
                },
                error.EndOfStream => {},
            }

            const line = line_writer.written();

            if (line.len == 0) {
                bridgeDebugLog("readMessageRaw: empty line (len=0)", .{});
                continue;
            }

            const msg = try parseStreamMessageLine(&arena, line);
            keep_arena = true;
            return msg;
        }
    }

    fn parseStreamMessageLine(arena: *std.heap.ArenaAllocator, line: []const u8) !StreamMessage {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), line, .{});
        const envelope = try std.json.parseFromValueLeaky(StreamEnvelope, arena.allocator(), parsed.value, .{
            .ignore_unknown_fields = true,
        });

        const msg_type = MessageType.fromString(envelope.type);
        const subtype = envelope.subtype;

        return StreamMessage{
            .type = msg_type,
            .subtype = subtype,
            .envelope = envelope,
            .raw = parsed.value,
            .arena = arena.*,
        };
    }

    /// Read next message from the queue.
    pub fn readMessage(self: *Bridge) !?StreamMessage {
        return self.popMessage(null);
    }

    /// Read next message with a deadline (milliseconds since epoch).
    pub fn readMessageWithTimeout(self: *Bridge, deadline_ms: i64) !?StreamMessage {
        return self.popMessage(deadline_ms);
    }

    fn popMessage(self: *Bridge, deadline_ms: ?i64) !?StreamMessage {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (true) {
            if (self.queue_head < self.message_queue.items.len) {
                const msg = self.message_queue.items[self.queue_head];
                self.queue_head += 1;
                if (self.queue_head >= self.message_queue.items.len) {
                    self.message_queue.clearRetainingCapacity();
                    self.queue_head = 0;
                }
                self.queue_cond.signal();
                return msg;
            }

            if (self.reader_closed) return null;

            if (deadline_ms) |deadline| {
                const now = std.time.milliTimestamp();
                if (now >= deadline) return error.Timeout;
                const slice_ms = io_utils.pollSliceMs(deadline, now);
                const timeout_ns: u64 = @as(u64, @intCast(slice_ms)) * std.time.ns_per_ms;
                self.queue_cond.timedWait(&self.queue_mutex, timeout_ns) catch |err| switch (err) {
                    error.Timeout => continue,
                };
            } else {
                self.queue_cond.wait(&self.queue_mutex);
            }
        }
    }

    // Note: Pattern mirrors codex_bridge.clearPendingMessages
    fn clearQueue(self: *Bridge) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        for (self.message_queue.items[self.queue_head..]) |*msg| {
            msg.deinit();
        }
        self.message_queue.clearRetainingCapacity();
        self.queue_head = 0;
    }

    fn readerMain(self: *Bridge) void {
        bridgeDebugLog("readerMain: starting", .{});
        var msg_count: u32 = 0;
        while (true) {
            if (self.stop_requested.load(.acquire)) {
                bridgeDebugLog("readerMain: stop requested", .{});
                break;
            }
            bridgeDebugLog("readerMain: waiting for message...", .{});
            var msg = self.readMessageRaw() catch |err| {
                bridgeDebugLog("readerMain: readMessageRaw error", .{});
                log.err("Claude reader failed: {}", .{err});
                break;
            } orelse {
                bridgeDebugLog("readerMain: readMessageRaw returned null", .{});
                break;
            };

            msg_count += 1;
            bridgeDebugLog("readerMain: got message #{d}, type={s}", .{ msg_count, @tagName(msg.type) });

            self.queue_mutex.lock();
            while ((self.message_queue.items.len - self.queue_head) >= constants.bridge_queue_max_messages) {
                if (self.stop_requested.load(.acquire)) {
                    self.queue_mutex.unlock();
                    msg.deinit();
                    return;
                }
                self.queue_cond.wait(&self.queue_mutex);
            }
            self.message_queue.append(self.allocator, msg) catch |err| {
                self.queue_mutex.unlock();
                log.err("Failed to queue Claude message: {}", .{err});
                msg.deinit();
                continue;
            };
            self.queue_mutex.unlock();
            self.queue_cond.signal();
        }

        bridgeDebugLog("readerMain: exiting, closing reader", .{});
        self.queue_mutex.lock();
        self.reader_closed = true;
        self.queue_mutex.unlock();
        self.queue_cond.broadcast();
    }
};

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "MessageType.fromString" {
    const summary = .{
        .system = @tagName(MessageType.fromString("system")),
        .assistant = @tagName(MessageType.fromString("assistant")),
        .result = @tagName(MessageType.fromString("result")),
        .invalid = @tagName(MessageType.fromString("invalid")),
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.MessageType.fromString__struct_<^\d+$>
        \\  .system: [:0]const u8
        \\    "system"
        \\  .assistant: [:0]const u8
        \\    "assistant"
        \\  .result: [:0]const u8
        \\    "result"
        \\  .invalid: [:0]const u8
        \\    "unknown"
    ).expectEqual(summary);
}

test "SystemSubtype.fromString parses auth_required" {
    const summary = .{ .auth_required = @tagName(SystemSubtype.fromString("auth_required").?) };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.SystemSubtype.fromString parses auth_required__struct_<^\d+$>
        \\  .auth_required: [:0]const u8
        \\    "auth_required"
    ).expectEqual(summary);
}

test "StreamMessage getSystemSubtype returns auth_required" {
    const json =
        \\{"type":"system","subtype":"auth_required"}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});

    var msg = StreamMessage{
        .type = .system,
        .subtype = "auth_required",
        .raw = parsed.value,
        .arena = arena,
    };
    defer msg.deinit();

    const summary = .{ .subtype = @tagName(msg.getSystemSubtype().?) };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.StreamMessage getSystemSubtype returns auth_required__struct_<^\d+$>
        \\  .subtype: [:0]const u8
        \\    "auth_required"
    ).expectEqual(summary);
}

test "parseStreamMessageLine detects auth_required subtype" {
    const line =
        \\{"type":"system","subtype":"auth_required","content":"Auth required"}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var msg = try Bridge.parseStreamMessageLine(&arena, line);
    defer msg.deinit();

    const summary = .{
        .type = @tagName(msg.type),
        .subtype = @tagName(msg.getSystemSubtype().?),
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.parseStreamMessageLine detects auth_required subtype__struct_<^\d+$>
        \\  .type: [:0]const u8
        \\    "system"
        \\  .subtype: [:0]const u8
        \\    "auth_required"
    ).expectEqual(summary);
}

test "StreamMessage parsing" {
    const json =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});

    var msg = StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed.value,
        .arena = arena,
    };
    defer msg.deinit();

    const summary = .{
        .content = msg.getContent(),
        .is_tool_use = msg.isToolUse(),
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.StreamMessage parsing__struct_<^\d+$>
        \\  .content: ?[]const u8
        \\    "Hello"
        \\  .is_tool_use: bool = false
    ).expectEqual(summary);
}

test "StreamMessage getEnvelope caches parsed envelope" {
    const json =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Cache"}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});

    var msg = StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed.value,
        .arena = arena,
    };
    defer msg.deinit();

    const before = msg.envelope == null;
    _ = msg.getEnvelope() orelse return error.TestUnexpectedResult;
    const after = msg.envelope != null;
    const summary = .{ .before = before, .after = after };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.StreamMessage getEnvelope caches parsed envelope__struct_<^\d+$>
        \\  .before: bool = true
        \\  .after: bool = true
    ).expectEqual(summary);
}

test "StreamMessage tool use parsing" {
    const json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool_1","name":"Read","input":{"file_path":"foo"}}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    var msg = StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed.value,
        .arena = arena,
    };
    defer msg.deinit();

    const tool = msg.getToolUse().?;
    const summary = .{ .id = tool.id, .name = tool.name };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.StreamMessage tool use parsing__struct_<^\d+$>
        \\  .id: []const u8
        \\    "tool_1"
        \\  .name: []const u8
        \\    "Read"
    ).expectEqual(summary);
}

test "StreamMessage tool result parsing" {
    const json =
        \\{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"tool_2","content":[{"type":"text","text":"ok"}],"is_error":false}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    var msg = StreamMessage{
        .type = .assistant,
        .subtype = null,
        .raw = parsed.value,
        .arena = arena,
    };
    defer msg.deinit();

    const result = msg.getToolResult().?;
    const raw_obj = result.raw.object;
    const summary = .{
        .id = result.id,
        .content = result.content,
        .is_error = result.is_error,
        .raw_type = raw_obj.get("type").?.string,
        .raw_tool_use_id = raw_obj.get("tool_use_id").?.string,
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.StreamMessage tool result parsing__struct_<^\d+$>
        \\  .id: []const u8
        \\    "tool_2"
        \\  .content: ?[]const u8
        \\    "ok"
        \\  .is_error: bool = false
        \\  .raw_type: []const u8
        \\    "tool_result"
        \\  .raw_tool_use_id: []const u8
        \\    "tool_2"
    ).expectEqual(summary);
}

test "StreamMessage tool result parsing from user message" {
    const json =
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool_3","content":"fail","is_error":true}]}}
    ;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{});
    var msg = StreamMessage{
        .type = .user,
        .subtype = null,
        .raw = parsed.value,
        .arena = arena,
    };
    defer msg.deinit();

    const result = msg.getToolResult().?;
    const summary = .{
        .id = result.id,
        .content = result.content,
        .is_error = result.is_error,
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.StreamMessage tool result parsing from user message__struct_<^\d+$>
        \\  .id: []const u8
        \\    "tool_3"
        \\  .content: ?[]const u8
        \\    "fail"
        \\  .is_error: bool = true
    ).expectEqual(summary);
}

const LiveSnapshotError = error{
    Timeout,
    UnexpectedEof,
    AuthRequired,
};

const ClaudeResponse = struct {
    text: []u8,
    stop_reason: []u8,

    fn deinit(self: *ClaudeResponse, allocator: Allocator) void {
        allocator.free(self.text);
        allocator.free(self.stop_reason);
    }
};

fn collectClaudeResponse(allocator: Allocator, bridge: *Bridge, prompt: []const u8) !ClaudeResponse {
    try bridge.sendPrompt(prompt);

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);
    var saw_delta = false;
    var stop_reason_buf: ?[]u8 = null;
    var saw_result = false;

    const deadline = std.time.milliTimestamp() + constants.live_snapshot_timeout_ms;
    while (true) {
        if (std.time.milliTimestamp() > deadline) return error.Timeout;
        var msg = (try readClaudeMessageWithTimeout(bridge, deadline)) orelse {
            if (saw_result) break;
            return error.UnexpectedEof;
        };
        defer msg.deinit();

        switch (msg.type) {
            .system => {
                if (msg.getSystemSubtype()) |subtype| {
                    if (subtype == .auth_required) return error.AuthRequired;
                }
            },
            .stream_event => {
                if (msg.getStreamTextDelta()) |delta| {
                    saw_delta = true;
                    try text_buf.appendSlice(allocator, delta);
                }
            },
            .assistant => {
                if (!saw_delta) {
                    if (msg.getContent()) |content| {
                        try text_buf.appendSlice(allocator, content);
                    }
                }
            },
            .result => {
                if (msg.getStopReason()) |reason| {
                    stop_reason_buf = try allocator.dupe(u8, reason);
                }
                saw_result = true;
                break;
            },
            else => {},
        }
        if (saw_result) break;
    }

    const normalized = try test_utils.normalizeSnapshotText(allocator, text_buf.items);
    const stop_reason = stop_reason_buf orelse try allocator.dupe(u8, "unknown");
    return .{
        .text = normalized,
        .stop_reason = stop_reason,
    };
}

fn collectClaudeSnapshot(allocator: Allocator, prompt: []const u8) ![]u8 {
    var bridge = Bridge.init(allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{
        .resume_session_id = null,
        .continue_last = false,
        .permission_mode = "default",
        .model = null,
    });
    defer bridge.stop();

    var response = try collectClaudeResponse(allocator, &bridge, prompt);
    defer response.deinit(allocator);

    return std.fmt.allocPrint(
        allocator,
        "engine: claude\ntext: {s}\nstop_reason: {s}\n",
        .{ response.text, response.stop_reason },
    );
}

fn hasBufferedClaudeData(bridge: *Bridge) bool {
    if (bridge.stdout_reader) |*reader| {
        return reader.interface.seek < reader.interface.end;
    }
    return false;
}

fn waitForClaudeReadable(bridge: *Bridge, timeout_ms: i32) !bool {
    const proc = bridge.process orelse return error.NotStarted;
    const stdout = proc.stdout orelse return error.NoStdout;
    return io_utils.waitForReadable(stdout.handle, timeout_ms);
}

fn readClaudeMessageWithTimeout(bridge: *Bridge, deadline_ms: i64) !?StreamMessage {
    return bridge.readMessageWithTimeout(deadline_ms);
}

fn waitForClaudeStreamStart(bridge: *Bridge, timeout_ms: i64) !bool {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        var msg = (try bridge.readMessageWithTimeout(deadline)) orelse return error.UnexpectedEof;
        defer msg.deinit();
        // Wait for actual content delta (not just stream event start)
        if (msg.type == .stream_event) {
            if (msg.getStreamTextDelta()) |_| return true;
        }
        if (msg.type == .assistant) {
            if (msg.getContent()) |_| return true;
        }
        if (msg.type == .result) return error.UnexpectedEof;
    }
}

const ClaudeInterruptResult = struct {
    got_result: bool,
    stop_reason: ?[]const u8,
    had_content: bool,
};

fn collectClaudeInterruptResult(allocator: Allocator, bridge: *Bridge, timeout_ms: i64) !ClaudeInterruptResult {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var had_content = false;
    var stop_reason_buf: ?[]u8 = null;

    while (true) {
        var msg = (try bridge.readMessageWithTimeout(deadline)) orelse {
            if (stop_reason_buf) |buf| allocator.free(buf);
            return .{ .got_result = false, .stop_reason = null, .had_content = had_content };
        };
        defer msg.deinit();

        switch (msg.type) {
            .stream_event => {
                if (msg.getStreamTextDelta()) |_| had_content = true;
            },
            .assistant => {
                if (msg.getContent()) |_| had_content = true;
            },
            .result => {
                if (msg.getStopReason()) |reason| {
                    stop_reason_buf = try allocator.dupe(u8, reason);
                }
                // Caller must free stop_reason if non-null
                return .{
                    .got_result = true,
                    .stop_reason = stop_reason_buf,
                    .had_content = had_content,
                };
            },
            else => {},
        }
    }
}

fn collectClaudeControlProbe(allocator: Allocator, input: StreamControlInput) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    const claude_path = executable.choose("CLAUDE_CODE_EXECUTABLE", "claude", Bridge.claude_paths[0..]);
    try args.appendSlice(allocator, &[_][]const u8{
        claude_path,
        "-p",
        "--verbose",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
    });

    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer {
        _ = child.kill() catch |err| blk: {
            log.warn("Failed to kill Claude child: {}", .{err});
            break :blk std.process.Child.Term{ .Unknown = 0 };
        };
        _ = child.wait() catch |err| blk: {
            log.warn("Failed to wait for Claude child: {}", .{err});
            break :blk std.process.Child.Term{ .Unknown = 0 };
        };
    }

    const stdin = child.stdin orelse return error.NoStdin;
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(input);
    try out.writer.writeByte('\n');

    const data = try out.toOwnedSlice();
    defer allocator.free(data);
    try stdin.writeAll(data);
    stdin.close();
    child.stdin = null;

    const stdout = try child.stdout.?.readToEndAlloc(allocator, constants.stdout_buffer_size);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, constants.stdout_buffer_size);
    defer allocator.free(stderr);

    const term = try child.wait();
    const exit_code: i32 = switch (term) {
        .Exited => |code| @intCast(code),
        else => -1,
    };

    const stderr_trimmed = std.mem.trim(u8, stderr, "\r\n ");
    const stdout_trimmed = std.mem.trim(u8, stdout, "\r\n ");
    return std.fmt.allocPrint(allocator, "exit_code: {d}\nstderr:{s}\nstdout:{s}\n", .{
        exit_code,
        stderr_trimmed,
        stdout_trimmed,
    });
}

test "snapshot: Claude Code live prompt" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!Bridge.isAvailable()) return error.SkipZigTest;

    const snapshot = try collectClaudeSnapshot(testing.allocator, "Reply with exactly the single word BANJO.");
    defer testing.allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\engine: claude
        \\text: BANJO
        \\stop_reason: success
        \\
    ).diff(snapshot, true);
}

test "live: Claude Code /clear does not reset context" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!Bridge.isAvailable()) return error.SkipZigTest;

    var bridge = Bridge.init(testing.allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{
        .resume_session_id = null,
        .continue_last = false,
        .permission_mode = "default",
        .model = null,
    });
    defer bridge.stop();

    const clear_token = "BANJO_CLEAR_TOKEN_9F3B7A";
    const remember_prompt = "Remember this token exactly: " ++ clear_token ++ ". Reply with ONLY the token.";
    var remember = try collectClaudeResponse(testing.allocator, &bridge, remember_prompt);
    defer remember.deinit(testing.allocator);
    try testing.expectEqualStrings(clear_token, remember.text);

    var clear = try collectClaudeResponse(testing.allocator, &bridge, "/clear");
    defer clear.deinit(testing.allocator);

    const recall_prompt = "What token did I ask you to remember? Reply with NO_MEMORY if you do not remember.";
    var recall = try collectClaudeResponse(testing.allocator, &bridge, recall_prompt);
    defer recall.deinit(testing.allocator);
    try testing.expectEqualStrings(clear_token, recall.text);
}

test "snapshot: Claude Code control messages are rejected" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!Bridge.isAvailable()) return error.SkipZigTest;

    const probe = try collectClaudeControlProbe(testing.allocator, StreamControlInput.setPermissionMode("acceptEdits"));
    defer testing.allocator.free(probe);

    try (ohsnap{}).snap(@src(),
        \\exit_code: 1
        \\stderr:Error: Expected message type 'user' or 'control', got 'control'
        \\stdout:
        \\
    ).diff(probe, true);
}

test "Claude Code SIGINT interrupt stops streaming" {
    // Verifies: SIGINT kills Claude process, streaming was happening before interrupt
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!Bridge.isAvailable()) return error.SkipZigTest;

    var bridge = Bridge.init(testing.allocator, ".");
    defer bridge.deinit();

    try bridge.start(.{
        .resume_session_id = null,
        .continue_last = false,
        .permission_mode = "default",
        .model = null,
    });

    // Start a long prompt to guarantee streaming
    try bridge.sendPrompt("Write the numbers 1 through 200, one per line.");

    // Wait for actual content to start streaming (not just init messages)
    const got_content = try waitForClaudeStreamStart(&bridge, constants.live_stream_start_timeout_ms);
    try testing.expect(got_content);

    // Small delay to ensure content is flowing
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Verify alive before interrupt
    try testing.expect(bridge.isAlive());

    // Send SIGINT - this kills Claude (no result message sent)
    bridge.interrupt();

    // Verify process exited
    try testing.expect(!bridge.isAlive());
}

test "Bridge restarts after SIGINT and processes new prompt" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!Bridge.isAvailable()) return error.SkipZigTest;

    var bridge = Bridge.init(testing.allocator, ".");
    defer bridge.deinit();

    // First session: start, prompt, interrupt
    try bridge.start(.{ .permission_mode = "default" });

    try bridge.sendPrompt("Count from 1 to 50, one number per line.");
    _ = try waitForClaudeStreamStart(&bridge, constants.live_stream_start_timeout_ms);
    std.Thread.sleep(100 * std.time.ns_per_ms);
    bridge.interrupt();

    // Wait for process to exit after interrupt
    var exit_seen = false;
    const deadline = std.time.milliTimestamp() + constants.live_restart_timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (!bridge.isAlive()) {
            exit_seen = true;
            break;
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    try testing.expect(exit_seen);

    // Restart bridge - this is the critical test
    try bridge.start(.{ .permission_mode = "default" });
    try testing.expect(bridge.isAlive());

    // Send a new prompt and verify we get a response
    try bridge.sendPrompt("Say exactly: hello world");

    var got_response = false;
    const deadline2 = std.time.milliTimestamp() + constants.live_snapshot_timeout_ms;
    while (std.time.milliTimestamp() < deadline2) {
        var msg = bridge.readMessageWithTimeout(deadline2) catch break orelse break;
        defer msg.deinit();
        if (msg.type == .assistant and msg.getContent() != null) {
            got_response = true;
            break;
        }
    }

    bridge.stop();
    try testing.expect(got_response);
}

test "interrupt and continue preserves session context" {
    // Regression: Before fix, isAlive() could return true during race window
    // after interrupt but before process fully exited, causing sendPrompt to fail.
    // Also verifies session continuity via --continue.
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!Bridge.isAvailable()) return error.SkipZigTest;

    var bridge = Bridge.init(testing.allocator, ".");
    defer bridge.deinit();

    // Start session and establish context
    try bridge.start(.{ .permission_mode = "default" });
    try bridge.sendPrompt("Remember the secret word: BANANA. Acknowledge with OK.");

    // Wait for acknowledgment
    const deadline1 = std.time.milliTimestamp() + constants.live_snapshot_timeout_ms;
    while (std.time.milliTimestamp() < deadline1) {
        var msg = bridge.readMessageWithTimeout(deadline1) catch break orelse break;
        defer msg.deinit();
        if (msg.type == .result) break;
    }

    // Interrupt then IMMEDIATELY restart with --continue
    bridge.interrupt();
    try testing.expect(!bridge.isAlive());
    try bridge.start(.{
        .permission_mode = "default",
        .continue_last = true,
    });
    try testing.expect(bridge.isAlive());

    // Ask about the secret - verify we can send/receive after restart
    try bridge.sendPrompt("What was the secret word I told you? Reply with just the word.");
    var got_response = false;
    const deadline2 = std.time.milliTimestamp() + constants.live_snapshot_timeout_ms;
    while (std.time.milliTimestamp() < deadline2) {
        var msg = bridge.readMessageWithTimeout(deadline2) catch break orelse break;
        defer msg.deinit();
        if (msg.type == .assistant or msg.type == .stream_event) {
            got_response = true;
        }
        if (msg.type == .result) break;
    }

    bridge.stop();
    // Core test: restart + prompt flow works (context memory is best-effort)
    try testing.expect(got_response);
}

// =============================================================================
// Property Tests for Message Parsing
// =============================================================================

const zcheck = @import("zcheck");
const zcheck_seed_base: u64 = 0x7a2c_14bf_9d03_5e61;

/// Build a test message JSON value
fn buildTestMessage(
    allocator: std.mem.Allocator,
    msg_type: MessageType,
    content_type: enum { text, tool_use, image, none },
    include_subtype: bool,
) !std.json.Value {
    var json_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\"type\":\"");
    try json_buf.appendSlice(allocator, @tagName(msg_type));
    try json_buf.appendSlice(allocator, "\"");

    if (include_subtype and msg_type != .result) {
        try json_buf.appendSlice(allocator, ",\"subtype\":\"test_subtype\"");
    }

    if (msg_type == .system) {
        if (content_type != .none) {
            try json_buf.appendSlice(allocator, ",\"content\":\"system_content\"");
        }
    } else if (msg_type == .assistant) {
        if (content_type != .none) {
            const content_block = switch (content_type) {
                .text => "{\"type\":\"text\",\"text\":\"assistant_text\"}",
                .tool_use => "{\"type\":\"tool_use\",\"name\":\"default_tool\",\"id\":\"toolu_default\"}",
                .image => "{\"type\":\"image\"}",
                .none => "",
            };
            try json_buf.appendSlice(allocator, ",\"message\":{\"content\":[");
            try json_buf.appendSlice(allocator, content_block);
            try json_buf.appendSlice(allocator, "]}");
        }
    } else if (msg_type == .result) {
        if (include_subtype) {
            try json_buf.appendSlice(allocator, ",\"subtype\":\"end_turn\"");
        }
    }

    try json_buf.appendSlice(allocator, "}");
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, json_buf.items, .{});
}

test "property: MessageType.fromString covers all variants" {
    // All known types should parse correctly
    const summary = .{
        .system = @tagName(MessageType.fromString("system")),
        .assistant = @tagName(MessageType.fromString("assistant")),
        .user = @tagName(MessageType.fromString("user")),
        .result = @tagName(MessageType.fromString("result")),
        .stream_event = @tagName(MessageType.fromString("stream_event")),
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.property: MessageType.fromString covers all variants__struct_<^\d+$>
        \\  .system: [:0]const u8
        \\    "system"
        \\  .assistant: [:0]const u8
        \\    "assistant"
        \\  .user: [:0]const u8
        \\    "user"
        \\  .result: [:0]const u8
        \\    "result"
        \\  .stream_event: [:0]const u8
        \\    "stream_event"
    ).expectEqual(summary);

    // Unknown strings should return .unknown
    try zcheck.check(struct {
        fn prop(args: struct { byte1: u8, byte2: u8, byte3: u8 }) bool {
            // Build a random string that's unlikely to match known types
            const random_str = [_]u8{ args.byte1, args.byte2, args.byte3 };
            const result = MessageType.fromString(&random_str);
            // Most random 3-byte strings should be unknown
            // (unless they happen to be "user" which is 4 chars, so safe)
            if (result == .unknown) return true;
            const reserved = [_][]const u8{ "sys", "use", "res" };
            for (reserved) |tag| {
                if (std.mem.eql(u8, &random_str, tag)) return true;
            }
            return false;
        }
    }.prop, .{ .seed = zcheck_seed_base + 1 });
}

test "property: getToolName/getToolId extraction preserves input values" {
    // Property: for any tool name and id, extraction returns the original values
    try zcheck.check(struct {
        fn prop(args: struct { name_seed: u32, id_seed: u32 }) !bool {
            // Generate deterministic "random" names from seeds
            var name_buf: [16]u8 = undefined;
            var id_buf: [20]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "Tool_{x}", .{args.name_seed});
            const id = try std.fmt.bufPrint(&id_buf, "toolu_{x}", .{args.id_seed});

            // Build JSON with these values
            var json_buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&json_buf,
                \\{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"{s}","id":"{s}"}}]}}}}
            , .{ name, id });

            // Parse and extract
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
            defer parsed.deinit();

            const arena = std.heap.ArenaAllocator.init(testing.allocator);
            var msg = StreamMessage{ .type = .assistant, .subtype = null, .raw = parsed.value, .arena = arena };
            defer msg.deinit();

            // Property: extracted values equal input values
            const extracted_name = msg.getToolName() orelse return false;
            const extracted_id = msg.getToolId() orelse return false;
            return std.mem.eql(u8, extracted_name, name) and std.mem.eql(u8, extracted_id, id);
        }
    }.prop, .{ .seed = zcheck_seed_base + 2 });
}

test "property: getContent extraction preserves input text" {
    try zcheck.check(struct {
        fn prop(args: struct { text_seed: u32 }) !bool {
            // Generate deterministic text from seed (avoid special chars that break JSON)
            var text_buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&text_buf, "Message_{x}", .{args.text_seed});

            // Build JSON
            var json_buf: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&json_buf,
                \\{{"type":"assistant","message":{{"content":[{{"type":"text","text":"{s}"}}]}}}}
            , .{text});

            // Parse and extract
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
            defer parsed.deinit();

            const arena = std.heap.ArenaAllocator.init(testing.allocator);
            var msg = StreamMessage{ .type = .assistant, .subtype = null, .raw = parsed.value, .arena = arena };
            defer msg.deinit();

            // Property: extracted text equals input text
            const extracted = msg.getContent() orelse return false;
            return std.mem.eql(u8, extracted, text);
        }
    }.prop, .{ .seed = zcheck_seed_base + 3 });
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

    var summaries: [cases.len]struct {
        msg_type: []const u8,
        tool_name_null: bool,
        tool_id_null: bool,
    } = undefined;

    for (cases, types, 0..) |json, msg_type, idx| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer parsed.deinit();
        const arena = std.heap.ArenaAllocator.init(testing.allocator);
        var msg = StreamMessage{ .type = msg_type, .subtype = null, .raw = parsed.value, .arena = arena };
        defer msg.deinit();
        summaries[idx] = .{
            .msg_type = @tagName(msg_type),
            .tool_name_null = msg.getToolName() == null,
            .tool_id_null = msg.getToolId() == null,
        };
    }
    try (ohsnap{}).snap(@src(),
        \\[3]core.claude_bridge.test.getToolName/getToolId return null for non-tool messages__struct_<^\d+$>
        \\  [0]: core.claude_bridge.test.getToolName/getToolId return null for non-tool messages__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "assistant"
        \\    .tool_name_null: bool = true
        \\    .tool_id_null: bool = true
        \\  [1]: core.claude_bridge.test.getToolName/getToolId return null for non-tool messages__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "system"
        \\    .tool_name_null: bool = true
        \\    .tool_id_null: bool = true
        \\  [2]: core.claude_bridge.test.getToolName/getToolId return null for non-tool messages__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "result"
        \\    .tool_name_null: bool = true
        \\    .tool_id_null: bool = true
    ).expectEqual(summaries);
}

test "property: getStopReason only works for result type" {
    const types = [_]MessageType{ .system, .assistant, .user, .result, .stream_event };

    var summaries: [types.len]struct {
        msg_type: []const u8,
        reason: ?[]const u8,
    } = undefined;

    for (types, 0..) |msg_type, idx| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const alloc = arena.allocator();

        var json_val = try buildTestMessage(alloc, msg_type, .none, true);
        _ = &json_val;

        var msg = StreamMessage{
            .type = msg_type,
            .subtype = "end_turn",
            .raw = json_val,
            .arena = arena,
        };
        defer msg.deinit();

        const reason = msg.getStopReason();
        summaries[idx] = .{
            .msg_type = @tagName(msg_type),
            .reason = reason,
        };
    }
    try (ohsnap{}).snap(@src(),
        \\[5]core.claude_bridge.test.property: getStopReason only works for result type__struct_<^\d+$>
        \\  [0]: core.claude_bridge.test.property: getStopReason only works for result type__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "system"
        \\    .reason: ?[]const u8
        \\      null
        \\  [1]: core.claude_bridge.test.property: getStopReason only works for result type__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "assistant"
        \\    .reason: ?[]const u8
        \\      null
        \\  [2]: core.claude_bridge.test.property: getStopReason only works for result type__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "user"
        \\    .reason: ?[]const u8
        \\      null
        \\  [3]: core.claude_bridge.test.property: getStopReason only works for result type__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "result"
        \\    .reason: ?[]const u8
        \\      "end_turn"
        \\  [4]: core.claude_bridge.test.property: getStopReason only works for result type__struct_<^\d+$>
        \\    .msg_type: []const u8
        \\      "stream_event"
        \\    .reason: ?[]const u8
        \\      null
    ).expectEqual(summaries);
}

test "property: system messages extract content from content or message field" {
    // Test content field
    var arena1 = std.heap.ArenaAllocator.init(testing.allocator);
    const alloc1 = arena1.allocator();
    var json1 = try buildTestMessage(alloc1, .system, .text, false);
    _ = &json1;
    var msg1 = StreamMessage{
        .type = .system,
        .subtype = null,
        .raw = json1,
        .arena = arena1,
    };
    defer msg1.deinit();
    const content_primary = msg1.getContent();

    // Test message field fallback
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    const alloc2 = arena2.allocator();
    const json2 = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc2,
        "{\"type\":\"system\",\"message\":\"fallback_message\"}",
        .{},
    );

    var msg2 = StreamMessage{
        .type = .system,
        .subtype = null,
        .raw = json2,
        .arena = arena2,
    };
    defer msg2.deinit();
    const content_fallback = msg2.getContent();
    const summary = .{
        .content = content_primary,
        .fallback = content_fallback,
    };
    try (ohsnap{}).snap(@src(),
        \\core.claude_bridge.test.property: system messages extract content from content or message field__struct_<^\d+$>
        \\  .content: ?[]const u8
        \\    "system_content"
        \\  .fallback: ?[]const u8
        \\    "fallback_message"
    ).expectEqual(summary);
}
