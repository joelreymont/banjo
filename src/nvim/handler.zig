const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const mcp_server_mod = @import("mcp_server.zig");
const mcp_types = @import("mcp_types.zig");
const core_types = @import("../core/types.zig");
const Engine = core_types.Engine;
const callbacks_mod = @import("../core/callbacks.zig");
const EditorCallbacks = callbacks_mod.EditorCallbacks;
const ToolKind = callbacks_mod.ToolKind;
const ToolStatus = callbacks_mod.ToolStatus;
const ApprovalKind = callbacks_mod.ApprovalKind;
const engine_mod = @import("../core/engine.zig");
const claude_bridge = @import("../core/claude_bridge.zig");
const codex_bridge = @import("../core/codex_bridge.zig");
const settings = @import("../core/settings.zig");
const permission_socket = @import("../core/permission_socket.zig");
const config = @import("config");

const log = std.log.scoped(.nvim);

// Comptime debug logging for nvim handler troubleshooting
const nvim_debug = config.nvim_debug;

var debug_file: ?std.fs.File = null;
var debug_buf: [4096]u8 = undefined;

fn initDebugLog() void {
    if (nvim_debug and debug_file == null) {
        debug_file = std.fs.cwd().createFile("/tmp/banjo-nvim-debug.log", .{ .truncate = true }) catch null;
    }
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (nvim_debug) {
        if (debug_file) |f| {
            const msg = std.fmt.bufPrint(&debug_buf, "[DEBUG] " ++ fmt ++ "\n", args) catch return;
            _ = f.write(msg) catch {};
        }
    }
}

pub const Handler = struct {
    allocator: Allocator,
    stdin: std.io.AnyReader,
    stdout: std.io.AnyWriter,
    cwd: []const u8,
    owns_cwd: bool,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    nudge_enabled: bool = true,
    last_nudge_ms: i64 = 0,
    claude_session_id: ?[]const u8 = null,
    codex_session_id: ?[]const u8 = null,
    mcp_server: ?*mcp_server_mod.McpServer = null,
    should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_thread: ?std.Thread = null,

    // State for engine/model/mode selection
    current_engine: Engine = .claude,
    current_model: ?[]const u8 = null,
    permission_mode: protocol.PermissionMode = .default,

    // Session state
    session_active: bool = false,

    // Pending approval request (for Codex)
    pending_approval_id: ?[]const u8 = null,
    pending_approval_response: ?[]const u8 = null,

    // Permission socket for Claude Code hook (like ACP agent)
    permission_socket: ?std.posix.socket_t = null,
    permission_socket_path: ?[]const u8 = null,
    nvim_session_id: ?[]const u8 = null,
    always_allowed_tools: std.StringHashMap(void),

    // Pending permission request (for Claude Code)
    pending_permission_id: ?[]const u8 = null,
    pending_permission_response: ?[]const u8 = null,
    permission_client_fd: ?std.posix.socket_t = null,

    // Message queue for decoupling poll thread from processing
    pending_prompt: ?PendingPrompt = null,
    prompt_mutex: std.Thread.Mutex = .{},
    prompt_ready: std.Thread.Condition = .{},

    // Pending continuation prompt (for nudge/dots auto-continue)
    pending_continuation: ?PendingContinuation = null,

    const PendingPrompt = struct {
        text: []const u8,
        cwd: ?[]const u8,
    };

    const PendingContinuation = struct {
        text: []const u8,
        engine: Engine,
    };

    pub fn init(allocator: Allocator, stdin: std.io.AnyReader, stdout: std.io.AnyWriter) Handler {
        const cwd_result = std.process.getCwdAlloc(allocator);
        const cwd = cwd_result catch "/";
        const owns_cwd = if (cwd_result) |_| true else |_| false;
        return Handler{
            .allocator = allocator,
            .stdin = stdin,
            .stdout = stdout,
            .cwd = cwd,
            .owns_cwd = owns_cwd,
            .always_allowed_tools = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Handler) void {
        // Signal threads to exit
        self.should_exit.store(true, .release);
        self.prompt_ready.signal(); // Wake main thread if waiting

        // Wait for poll thread
        if (self.poll_thread) |thread| {
            thread.join();
        }

        // Clean up pending prompt if any
        if (self.pending_prompt) |p| {
            self.allocator.free(p.text);
            if (p.cwd) |c| self.allocator.free(c);
        }

        // Clean up pending continuation if any
        if (self.pending_continuation) |c| {
            self.allocator.free(c.text);
        }

        if (self.mcp_server) |mcp| {
            mcp.deinit();
        }
        if (self.claude_session_id) |sid| self.allocator.free(sid);
        if (self.codex_session_id) |sid| self.allocator.free(sid);
        if (self.current_model) |model| self.allocator.free(model);
        if (self.pending_approval_id) |id| self.allocator.free(id);
        if (self.pending_approval_response) |resp| self.allocator.free(resp);
        if (self.pending_permission_id) |id| self.allocator.free(id);
        if (self.pending_permission_response) |resp| self.allocator.free(resp);
        self.closePermissionSocket();
        if (self.nvim_session_id) |sid| self.allocator.free(sid);
        self.always_allowed_tools.deinit();
        if (self.owns_cwd) {
            self.allocator.free(self.cwd);
        }
    }

    fn generateSessionId(self: *Handler) ![]const u8 {
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        const hex = std.fmt.bytesToHex(buf, .lower);
        return try std.fmt.allocPrint(self.allocator, "nvim-{s}", .{&hex});
    }

    fn createPermissionSocket(self: *Handler) !void {
        if (self.nvim_session_id == null) {
            self.nvim_session_id = try self.generateSessionId();
        }

        const result = try permission_socket.create(self.allocator, self.nvim_session_id.?);
        self.permission_socket = result.socket;
        self.permission_socket_path = result.path;
    }

    fn closePermissionSocket(self: *Handler) void {
        if (self.permission_client_fd) |fd| {
            std.posix.close(fd);
            self.permission_client_fd = null;
        }
        if (self.permission_socket) |sock| {
            std.posix.close(sock);
            self.permission_socket = null;
        }
        if (self.permission_socket_path) |path| {
            std.fs.cwd().deleteFile(path) catch {};
            self.allocator.free(path);
            self.permission_socket_path = null;
        }
    }

    pub fn run(self: *Handler) !void {
        initDebugLog();
        debugLog("Handler.run starting", .{});

        // Configure permission hook and create socket for Claude Code
        const hook_result = settings.ensurePermissionHook(self.allocator);
        self.createPermissionSocket() catch |err| {
            log.warn("Failed to create permission socket: {}", .{err});
        };

        // Start MCP server for Claude CLI discovery and nvim WebSocket
        self.mcp_server = mcp_server_mod.McpServer.init(self.allocator, self.cwd) catch |err| {
            log.err("Failed to init MCP server: {}", .{err});
            return err;
        };

        // Notify user if permission hook was newly configured
        if (hook_result == .configured) {
            log.info("Configured Banjo permission hook - restart Claude Code for interactive prompts", .{});
        }

        if (self.mcp_server) |mcp| {
            // Set up nvim message callback
            mcp.nvim_message_callback = nvimMessageCallback;
            mcp.nvim_callback_ctx = @ptrCast(self);

            mcp.start() catch |err| {
                log.err("Failed to start MCP server: {}", .{err});
            };

            // Send ready notification via stdout (nvim uses this to connect via WebSocket)
            try self.sendStdoutNotification("ready", ReadyNotification{ .mcp_port = mcp.getPort() });
        } else {
            try self.sendStdoutNotification("ready", .{});
        }

        // Spawn poll thread to receive WebSocket messages
        self.poll_thread = std.Thread.spawn(.{}, pollThreadFn, .{self}) catch |err| {
            log.err("Failed to spawn poll thread: {}", .{err});
            return err;
        };

        // Main thread: wait for and process prompts
        debugLog("Main loop starting", .{});
        while (!self.should_exit.load(.acquire)) {
            // Wait for a prompt to be queued
            debugLog("Main loop waiting for prompt...", .{});
            self.prompt_mutex.lock();
            while (self.pending_prompt == null and !self.should_exit.load(.acquire)) {
                self.prompt_ready.wait(&self.prompt_mutex);
            }

            // Take the prompt
            const prompt = self.pending_prompt;
            self.pending_prompt = null;
            self.prompt_mutex.unlock();
            debugLog("Main loop woke up, prompt={}", .{prompt != null});

            // Process it (if we got one and not exiting)
            if (prompt) |p| {
                debugLog("Processing prompt: {d} bytes", .{p.text.len});
                self.processQueuedPrompt(p);
                debugLog("Prompt processing complete", .{});
            }
        }

        // Wait for poll thread to exit
        if (self.poll_thread) |thread| {
            thread.join();
            self.poll_thread = null;
        }
    }

    fn processQueuedPrompt(self: *Handler, prompt: PendingPrompt) void {
        debugLog("processQueuedPrompt: entry", .{});
        defer {
            self.allocator.free(prompt.text);
            if (prompt.cwd) |c| self.allocator.free(c);
        }

        // Emit session_start if not already in a session
        if (!self.session_active) {
            debugLog("processQueuedPrompt: starting new session", .{});
            self.session_active = true;
            self.sendNotification("session_start", protocol.SessionEvent{}) catch {};
            if (self.mcp_server) |mcp| {
                mcp.sendNvimNotification("session_start", protocol.SessionEvent{}) catch {};
            }
        }

        self.cancelled.store(false, .release);

        const req = protocol.PromptRequest{
            .text = prompt.text,
            .cwd = prompt.cwd,
        };

        debugLog("processQueuedPrompt: calling processPrompt", .{});
        self.processPrompt(req) catch |err| {
            debugLog("processQueuedPrompt: error!", .{});
            log.err("Prompt processing error: {}", .{err});
            self.sendError("Processing error") catch {};
        };
        debugLog("processQueuedPrompt: processPrompt returned", .{});

        // Process any pending continuation (from nudge/dots)
        while (self.pending_continuation) |continuation| {
            self.pending_continuation = null;
            defer self.allocator.free(continuation.text);

            if (self.cancelled.load(.acquire)) break;

            log.info("Processing continuation prompt for {s}", .{@tagName(continuation.engine)});
            self.cancelled.store(false, .release);

            // Override engine for continuation
            const saved_engine = self.current_engine;
            self.current_engine = continuation.engine;
            defer self.current_engine = saved_engine;

            const cont_req = protocol.PromptRequest{
                .text = continuation.text,
                .cwd = null,
            };

            self.processPrompt(cont_req) catch |err| {
                log.err("Continuation processing error: {}", .{err});
                self.sendError("Continuation error") catch {};
                break;
            };
        }
    }

    fn pollThreadFn(self: *Handler) void {
        debugLog("pollThreadFn starting", .{});
        while (!self.should_exit.load(.acquire)) {
            if (self.mcp_server) |mcp| {
                _ = mcp.poll(100) catch |err| {
                    log.warn("MCP poll error: {}", .{err});
                    continue;
                };
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
            // Poll permission socket for Claude Code hook requests
            self.pollPermissionSocket();
        }
        debugLog("pollThreadFn exiting", .{});
    }

    // Auto-approve these safe tools (matches ACP agent behavior)
    const always_approve_tools = std.StaticStringMap(void).initComptime(.{
        .{ "TodoWrite", {} },
        .{ "TodoRead", {} },
        .{ "Task", {} },
        .{ "TaskOutput", {} },
        .{ "AskUserQuestion", {} },
        .{ "Read", {} },
        .{ "Grep", {} },
        .{ "Glob", {} },
        .{ "LSP", {} },
    });

    // Edit tools - auto-approve in acceptEdits mode
    const edit_tools = std.StaticStringMap(void).initComptime(.{
        .{ "Write", {} },
        .{ "Edit", {} },
        .{ "MultiEdit", {} },
        .{ "NotebookEdit", {} },
    });

    const PermissionHookRequest = struct {
        tool_name: []const u8,
        tool_input: std.json.Value,
        tool_use_id: []const u8,
        session_id: []const u8,
    };

    fn pollPermissionSocket(self: *Handler) void {
        const sock = self.permission_socket orelse return;

        // Non-blocking accept
        const client_fd = std.posix.accept(sock, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC) catch |err| {
            if (err == error.WouldBlock) return;
            log.warn("Permission socket accept error: {}", .{err});
            return;
        };
        defer std.posix.close(client_fd);

        // Read request from hook
        var buf: [16384]u8 = undefined;
        var total_read: usize = 0;

        // Read until newline or buffer full
        while (total_read < buf.len - 1) {
            const n = std.posix.read(client_fd, buf[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                log.warn("Permission socket read error: {}", .{err});
                return;
            };
            if (n == 0) break;
            total_read += n;
            if (std.mem.indexOfScalar(u8, buf[0..total_read], '\n') != null) break;
        }

        if (total_read == 0) return;

        // Parse JSON request
        const json_str = std.mem.trimRight(u8, buf[0..total_read], "\n\r");
        const parsed = std.json.parseFromSlice(PermissionHookRequest, self.allocator, json_str, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Failed to parse permission request: {}", .{err});
            self.sendPermissionResponse(client_fd, "deny", null);
            return;
        };
        defer parsed.deinit();
        const req = parsed.value;

        log.info("Permission request for tool: {s}", .{req.tool_name});

        // Check auto-approve conditions
        const decision = self.checkPermissionAutoApprove(req.tool_name);
        if (decision) |d| {
            log.info("Auto-approving {s}: {s}", .{ req.tool_name, d });
            self.sendPermissionResponse(client_fd, d, null);
            return;
        }

        // Need to prompt user - store pending state
        if (self.pending_permission_id) |old| self.allocator.free(old);
        self.pending_permission_id = self.allocator.dupe(u8, req.tool_use_id) catch {
            self.sendPermissionResponse(client_fd, "deny", "out of memory");
            return;
        };
        self.pending_permission_response = null;

        // Format tool_input for display
        const tool_input_str = std.json.Stringify.valueAlloc(self.allocator, req.tool_input, .{}) catch null;
        defer if (tool_input_str) |s| self.allocator.free(s);

        // Send permission_request notification to Lua UI
        self.sendNotification("permission_request", protocol.PermissionRequest{
            .id = req.tool_use_id,
            .tool_name = req.tool_name,
            .tool_input = tool_input_str,
        }) catch |err| {
            log.err("Failed to send permission_request: {}", .{err});
            self.sendPermissionResponse(client_fd, "deny", "notification failed");
            return;
        };

        // Wait for response with 30s timeout
        const timeout_ms: i64 = 30_000;
        const start_time = std.time.milliTimestamp();

        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            // Check if cancelled
            if (self.cancelled.load(.acquire)) {
                self.sendPermissionResponse(client_fd, "deny", "cancelled");
                return;
            }

            // Check if we have a response
            if (self.pending_permission_response) |response| {
                // Clean up pending state
                if (self.pending_permission_id) |pid| {
                    self.allocator.free(pid);
                    self.pending_permission_id = null;
                }

                // Handle "allow_always" - add to always_allowed_tools
                if (std.mem.eql(u8, response, "allow_always")) {
                    const tool_name_copy = self.allocator.dupe(u8, req.tool_name) catch null;
                    if (tool_name_copy) |name| {
                        self.always_allowed_tools.put(name, {}) catch {
                            self.allocator.free(name);
                        };
                    }
                    self.sendPermissionResponse(client_fd, "allow", null);
                } else {
                    self.sendPermissionResponse(client_fd, response, null);
                }

                self.allocator.free(response);
                self.pending_permission_response = null;
                return;
            }

            // Poll MCP server for incoming messages from Lua
            if (self.mcp_server) |mcp| {
                _ = mcp.poll(100) catch {};
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        // Timeout - clean up and deny
        log.warn("Permission request timed out for {s}", .{req.tool_use_id});
        if (self.pending_permission_id) |pid| {
            self.allocator.free(pid);
            self.pending_permission_id = null;
        }
        self.sendPermissionResponse(client_fd, "deny", "timeout");
    }

    fn checkPermissionAutoApprove(self: *Handler, tool_name: []const u8) ?[]const u8 {
        // Always auto-approve safe tools
        if (always_approve_tools.has(tool_name)) {
            return "allow";
        }

        // User previously selected "Allow Always" for this tool
        if (self.always_allowed_tools.contains(tool_name)) {
            return "allow";
        }

        // Auto-approve in bypass mode
        if (self.permission_mode == .auto_approve) {
            return "allow";
        }

        // Auto-approve edit tools in acceptEdits mode
        if (self.permission_mode == .accept_edits and edit_tools.has(tool_name)) {
            return "allow";
        }

        return null;
    }

    const PermissionResponse = struct {
        decision: []const u8,
        reason: ?[]const u8 = null,
    };

    fn sendPermissionResponse(self: *Handler, client_fd: std.posix.socket_t, decision: []const u8, reason: ?[]const u8) void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .emit_null_optional_fields = false },
        };
        jw.write(PermissionResponse{ .decision = decision, .reason = reason }) catch return;
        out.writer.writeAll("\n") catch return;
        const json = out.toOwnedSlice() catch return;
        defer self.allocator.free(json);

        _ = std.posix.write(client_fd, json) catch |err| {
            log.warn("Failed to send permission response: {}", .{err});
        };
    }

    fn nvimMessageCallback(ctx: *anyopaque, method: []const u8, params: ?std.json.Value) void {
        const self: *Handler = @ptrCast(@alignCast(ctx));
        debugLog("nvimMessageCallback: method={s}", .{method});

        const method_map = std.StaticStringMap(NvimMethod).initComptime(.{
            .{ "prompt", .prompt },
            .{ "cancel", .cancel },
            .{ "nudge_toggle", .nudge_toggle },
            .{ "set_engine", .set_engine },
            .{ "set_model", .set_model },
            .{ "set_permission_mode", .set_permission_mode },
            .{ "get_state", .get_state },
            .{ "approval_response", .approval_response },
            .{ "permission_response", .permission_response },
            .{ "shutdown", .shutdown },
            .{ "tool_response", .tool_response },
            .{ "selection_changed", .selection_changed },
        });

        const kind = method_map.get(method) orelse {
            log.warn("Unknown nvim method: {s}", .{method});
            return;
        };

        switch (kind) {
            .prompt => self.handleNvimPrompt(params),
            .cancel => self.handleNvimCancel(),
            .nudge_toggle => self.handleNvimNudgeToggle(),
            .set_engine => self.handleNvimSetEngine(params),
            .set_model => self.handleNvimSetModel(params),
            .set_permission_mode => self.handleNvimSetPermissionMode(params),
            .get_state => self.handleNvimGetState(),
            .approval_response => self.handleNvimApprovalResponse(params),
            .permission_response => self.handleNvimPermissionResponse(params),
            .shutdown => self.handleNvimShutdown(),
            .tool_response => self.handleNvimToolResponse(params),
            .selection_changed => self.handleNvimSelectionChanged(params),
        }
    }

    const NvimMethod = enum {
        prompt,
        cancel,
        nudge_toggle,
        set_engine,
        set_model,
        set_permission_mode,
        get_state,
        approval_response,
        permission_response,
        shutdown,
        tool_response,
        selection_changed,
    };

    fn handleNvimPrompt(self: *Handler, params: ?std.json.Value) void {
        debugLog("handleNvimPrompt: entry", .{});
        const p = params orelse {
            debugLog("handleNvimPrompt: no params", .{});
            return;
        };
        const parsed = std.json.parseFromValue(protocol.PromptRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid prompt params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        debugLog("handleNvimPrompt: parsed text={d} bytes", .{parsed.value.text.len});

        // Clone the prompt data since we're queuing it
        const text = self.allocator.dupe(u8, parsed.value.text) catch {
            log.err("Failed to allocate prompt text", .{});
            return;
        };
        const cwd = if (parsed.value.cwd) |c| self.allocator.dupe(u8, c) catch null else null;

        // Queue the prompt and signal main thread
        debugLog("handleNvimPrompt: queuing prompt", .{});
        self.prompt_mutex.lock();
        // If there's already a pending prompt, free it (shouldn't happen normally)
        if (self.pending_prompt) |old| {
            debugLog("handleNvimPrompt: replacing existing prompt!", .{});
            self.allocator.free(old.text);
            if (old.cwd) |c| self.allocator.free(c);
        }
        self.pending_prompt = .{ .text = text, .cwd = cwd };
        self.prompt_mutex.unlock();
        debugLog("handleNvimPrompt: signaling main thread", .{});
        self.prompt_ready.signal();
        debugLog("handleNvimPrompt: done", .{});
    }

    fn handleNvimCancel(self: *Handler) void {
        // Emit session_end if session is active
        if (self.session_active) {
            self.session_active = false;
            self.sendNotification("session_end", protocol.SessionEvent{}) catch {};
            // Forward to MCP server
            if (self.mcp_server) |mcp| {
                mcp.sendNvimNotification("session_end", protocol.SessionEvent{}) catch {};
            }
        }

        self.cancelled.store(true, .release);

        // Clear pending prompt to prevent queued work from starting after cancel
        self.prompt_mutex.lock();
        if (self.pending_prompt) |p| {
            self.allocator.free(p.text);
            if (p.cwd) |c| self.allocator.free(c);
            self.pending_prompt = null;
        }
        self.prompt_mutex.unlock();

        // Clear pending continuation
        if (self.pending_continuation) |c| {
            self.allocator.free(c.text);
            self.pending_continuation = null;
        }

        self.sendNotification("status", protocol.StatusUpdate{ .text = "Cancelled" }) catch {};
    }

    fn handleNvimNudgeToggle(self: *Handler) void {
        self.nudge_enabled = !self.nudge_enabled;
        const status = if (self.nudge_enabled) "Nudge enabled" else "Nudge disabled";
        self.sendNotification("status", protocol.StatusUpdate{ .text = status }) catch {};
    }

    fn handleNvimSetEngine(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SetEngineRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid set_engine params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const engine_map = std.StaticStringMap(Engine).initComptime(.{
            .{ "claude", .claude },
            .{ "codex", .codex },
        });

        if (engine_map.get(parsed.value.engine)) |engine| {
            self.current_engine = engine;
            self.sendNotification("status", protocol.StatusUpdate{
                .text = if (engine == .claude) "Engine: Claude" else "Engine: Codex",
            }) catch {};
            self.sendStateNotification();
        } else {
            log.warn("Unknown engine: {s}", .{parsed.value.engine});
            self.sendError("Unknown engine") catch {};
        }
    }

    fn handleNvimSetModel(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SetModelRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid set_model params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Validate model name
        const valid_models = [_][]const u8{ "sonnet", "opus", "haiku" };
        var is_valid = false;
        for (valid_models) |m| {
            if (std.mem.eql(u8, parsed.value.model, m)) {
                is_valid = true;
                break;
            }
        }

        if (is_valid) {
            // Free old model if owned
            if (self.current_model) |old| {
                self.allocator.free(old);
            }
            self.current_model = self.allocator.dupe(u8, parsed.value.model) catch null;

            var buf: [64]u8 = undefined;
            const status = std.fmt.bufPrint(&buf, "Model: {s}", .{parsed.value.model}) catch "Model changed";
            self.sendNotification("status", protocol.StatusUpdate{ .text = status }) catch {};
            self.sendStateNotification();
        } else {
            log.warn("Invalid model: {s}", .{parsed.value.model});
            self.sendError("Invalid model (use: sonnet, opus, haiku)") catch {};
        }
    }

    fn handleNvimSetPermissionMode(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SetPermissionModeRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid set_permission_mode params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const mode_map = std.StaticStringMap(protocol.PermissionMode).initComptime(.{
            .{ "default", .default },
            .{ "accept_edits", .accept_edits },
            .{ "auto_approve", .auto_approve },
            .{ "plan_only", .plan_only },
        });

        if (mode_map.get(parsed.value.mode)) |mode| {
            self.permission_mode = mode;
            var buf: [64]u8 = undefined;
            const status = std.fmt.bufPrint(&buf, "Mode: {s}", .{mode.toString()}) catch "Mode changed";
            self.sendNotification("status", protocol.StatusUpdate{ .text = status }) catch {};
            self.sendStateNotification();
        } else {
            log.warn("Unknown mode: {s}", .{parsed.value.mode});
            self.sendError("Unknown mode (use: default, accept_edits, auto_approve, plan_only)") catch {};
        }
    }

    fn handleNvimGetState(self: *Handler) void {
        self.sendStateNotification();
    }

    fn handleNvimApprovalResponse(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.ApprovalResponseRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid approval_response params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Check if this matches the pending approval
        if (self.pending_approval_id) |pending_id| {
            if (std.mem.eql(u8, pending_id, parsed.value.id)) {
                // Store the response
                if (self.pending_approval_response) |old| {
                    self.allocator.free(old);
                }
                self.pending_approval_response = self.allocator.dupe(u8, parsed.value.decision) catch null;
                log.info("Received approval response: {s} for {s}", .{ parsed.value.decision, parsed.value.id });
            } else {
                log.warn("Approval response ID mismatch: expected {s}, got {s}", .{ pending_id, parsed.value.id });
            }
        } else {
            log.warn("Received approval response but no pending approval", .{});
        }
    }

    fn handleNvimPermissionResponse(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.PermissionResponseRequest, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid permission_response params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        // Check if this matches the pending permission request
        if (self.pending_permission_id) |pending_id| {
            if (std.mem.eql(u8, pending_id, parsed.value.id)) {
                // Store the response
                if (self.pending_permission_response) |old| {
                    self.allocator.free(old);
                }
                self.pending_permission_response = self.allocator.dupe(u8, parsed.value.decision) catch null;
                log.info("Received permission response: {s} for {s}", .{ parsed.value.decision, parsed.value.id });
            } else {
                log.warn("Permission response ID mismatch: expected {s}, got {s}", .{ pending_id, parsed.value.id });
            }
        } else {
            log.warn("Received permission response but no pending request", .{});
        }
    }

    fn sendStateNotification(self: *Handler) void {
        const engine_str: []const u8 = switch (self.current_engine) {
            .claude => "claude",
            .codex => "codex",
        };

        const session_id = switch (self.current_engine) {
            .claude => self.claude_session_id,
            .codex => self.codex_session_id,
        };

        self.sendNotification("state", protocol.StateResponse{
            .engine = engine_str,
            .model = self.current_model,
            .mode = self.permission_mode.toString(),
            .session_id = session_id,
            .connected = self.mcp_server != null,
        }) catch |err| {
            log.err("Failed to send state notification: {}", .{err});
        };
    }

    fn handleNvimShutdown(self: *Handler) void {
        log.info("Shutdown requested", .{});
        self.should_exit.store(true, .release);
        self.prompt_ready.signal(); // Wake up main thread
    }

    fn handleNvimToolResponse(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(ToolResponseParams, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid tool_response params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        if (self.mcp_server) |mcp| {
            mcp.handleToolResponse(
                parsed.value.correlation_id,
                parsed.value.result,
                parsed.value.@"error",
            ) catch |err| {
                log.warn("Failed to handle tool response: {}", .{err});
            };
        }
    }

    fn handleNvimSelectionChanged(self: *Handler, params: ?std.json.Value) void {
        const p = params orelse return;
        const parsed = std.json.parseFromValue(protocol.SelectionInfo, self.allocator, p, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("Invalid selection_changed params: {}", .{err});
            return;
        };
        defer parsed.deinit();

        if (self.mcp_server) |mcp| {
            const range: ?mcp_types.SelectionRange = if (parsed.value.range) |r| .{
                .startLine = r.start_line,
                .startCol = r.start_col,
                .endLine = r.end_line,
                .endCol = r.end_col,
            } else null;

            mcp.updateSelection(.{
                .text = parsed.value.content orelse "",
                .file = parsed.value.file,
                .range = range,
            }) catch |err| {
                log.warn("Failed to update selection cache: {}", .{err});
            };
        }
    }

    fn processPrompt(self: *Handler, prompt_req: protocol.PromptRequest) !void {
        debugLog("processPrompt: entry, engine={s}", .{@tagName(self.current_engine)});
        const engine = self.current_engine;

        debugLog("processPrompt: sending stream_start notification", .{});
        try self.sendNotification("stream_start", protocol.StreamStart{ .engine = engine });

        var cb_ctx = CallbackContext{ .handler = self };
        const cbs = EditorCallbacks{
            .ctx = @ptrCast(&cb_ctx),
            .vtable = &callback_vtable,
        };

        var prompt_ctx = engine_mod.PromptContext{
            .allocator = self.allocator,
            .session_id = "nvim-session",
            .cwd = if (prompt_req.cwd) |c| c else self.cwd,
            .cancelled = &self.cancelled,
            .nudge = .{
                .enabled = self.nudge_enabled,
                .cooldown_ms = 30_000,
                .last_nudge_ms = &self.last_nudge_ms,
            },
            .cb = cbs,
            .tag_engine = false,
        };

        switch (engine) {
            .claude => {
                debugLog("processPrompt: initializing claude bridge", .{});
                var bridge = claude_bridge.Bridge.init(self.allocator, prompt_ctx.cwd);
                defer bridge.deinit();

                debugLog("processPrompt: starting claude bridge", .{});
                bridge.start(.{
                    .permission_mode = self.permission_mode.toCliArg(),
                    .model = self.current_model,
                    .permission_socket_path = self.permission_socket_path,
                }) catch |err| {
                    debugLog("processPrompt: bridge.start failed!", .{});
                    log.err("Failed to start Claude bridge: {}", .{err});
                    try self.sendError("Failed to start Claude");
                    return;
                };
                debugLog("processPrompt: bridge started, sending prompt", .{});

                bridge.sendPrompt(prompt_req.text) catch |err| {
                    debugLog("processPrompt: sendPrompt failed!", .{});
                    log.err("Failed to send prompt: {}", .{err});
                    try self.sendError("Failed to send prompt");
                    return;
                };
                debugLog("processPrompt: prompt sent, processing messages", .{});

                _ = engine_mod.processClaudeMessages(&prompt_ctx, &bridge) catch |err| {
                    debugLog("processPrompt: processClaudeMessages error!", .{});
                    log.err("Claude processing error: {}", .{err});
                };
            },
            .codex => {
                var bridge = codex_bridge.CodexBridge.init(self.allocator, prompt_ctx.cwd);
                defer bridge.deinit();

                bridge.start(.{
                    .approval_policy = self.permission_mode.toCodexApprovalPolicy(),
                }) catch |err| {
                    log.err("Failed to start Codex bridge: {}", .{err});
                    try self.sendError("Failed to start Codex");
                    return;
                };

                const inputs = [_]codex_bridge.UserInput{
                    .{ .type = "text", .text = prompt_req.text },
                };
                bridge.sendPrompt(&inputs) catch |err| {
                    log.err("Failed to send prompt: {}", .{err});
                    try self.sendError("Failed to send prompt");
                    return;
                };

                _ = engine_mod.processCodexMessages(&prompt_ctx, &bridge) catch |err| {
                    log.err("Codex processing error: {}", .{err});
                };
            },
        }

        try self.sendNotification("stream_end", .{});
    }

    const ReadyNotification = struct {
        mcp_port: u16,
    };

    const ToolResponseParams = struct {
        correlation_id: []const u8,
        result: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
    };

    /// Send notification via WebSocket to nvim client
    fn sendNotification(self: *Handler, method: []const u8, params: anytype) !void {
        debugLog("sendNotification: method={s}", .{method});
        const mcp = self.mcp_server orelse {
            debugLog("sendNotification: NotConnected!", .{});
            return error.NotConnected;
        };
        try mcp.sendNvimNotification(method, params);
        debugLog("sendNotification: sent", .{});
    }

    /// Send notification via stdout (used for initial ready message before WebSocket connects)
    fn sendStdoutNotification(self: *Handler, method: []const u8, params: anytype) !void {
        var out: std.io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        // Write JSON directly in one pass to avoid serialize-parse-serialize round-trip
        const T = @TypeOf(params);
        if (T == @TypeOf(.{})) {
            try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"");
            try out.writer.writeAll(method);
            try out.writer.writeAll("\"}");
        } else {
            try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"");
            try out.writer.writeAll(method);
            try out.writer.writeAll("\",\"params\":");
            var jw: std.json.Stringify = .{
                .writer = &out.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            try jw.write(params);
            try out.writer.writeAll("}");
        }

        try out.writer.writeAll("\n");
        const data = try out.toOwnedSlice();
        defer self.allocator.free(data);
        try self.stdout.writeAll(data);
    }

    fn sendError(self: *Handler, message: []const u8) !void {
        try self.sendNotification("error_msg", protocol.ErrorMessage{ .message = message });
    }

    // Callback implementations
    const CallbackContext = struct {
        handler: *Handler,
    };

    const callback_vtable = EditorCallbacks.VTable{
        .sendText = cbSendText,
        .sendTextRaw = cbSendTextRaw,
        .sendTextPrefix = cbSendTextPrefix,
        .sendThought = cbSendThought,
        .sendThoughtRaw = cbSendThoughtRaw,
        .sendThoughtPrefix = cbSendThoughtPrefix,
        .sendToolCall = cbSendToolCall,
        .sendToolResult = cbSendToolResult,
        .sendUserMessage = cbSendUserMessage,
        .onTimeout = cbOnTimeout,
        .onSessionId = cbOnSessionId,
        .onSlashCommands = null, // nvim handles slash commands locally
        .checkAuthRequired = cbCheckAuthRequired,
        .sendContinuePrompt = cbSendContinuePrompt,
        .onApprovalRequest = cbOnApprovalRequest,
    };

    fn cbSendText(ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void {
        _ = session_id;
        _ = engine;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text });
    }

    fn cbSendTextRaw(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text });
    }

    fn cbSendTextPrefix(ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_start", protocol.StreamStart{ .engine = engine });
    }

    fn cbSendThought(ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void {
        _ = session_id;
        _ = engine;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text, .is_thought = true });
    }

    fn cbSendThoughtRaw(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("stream_chunk", protocol.StreamChunk{ .text = text, .is_thought = true });
    }

    fn cbSendThoughtPrefix(ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = ctx;
    }

    // Tools that run silently without UI updates (internal housekeeping)
    const quiet_tools = std.StaticStringMap(void).initComptime(.{
        .{ "TodoWrite", {} },
        .{ "TodoRead", {} },
        .{ "TaskOutput", {} },
        .{ "Skill", {} },
        .{ "Read", {} },
        .{ "Write", {} },
        .{ "Edit", {} },
        .{ "MultiEdit", {} },
        .{ "NotebookRead", {} },
        .{ "NotebookEdit", {} },
        .{ "Grep", {} },
        .{ "Glob", {} },
        .{ "LSP", {} },
        .{ "KillShell", {} },
        .{ "EnterPlanMode", {} },
        .{ "ExitPlanMode", {} },
    });

    fn cbSendToolCall(ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_name: []const u8, tool_label: []const u8, tool_id: []const u8, kind: ToolKind, input: ?std.json.Value) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = kind;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));

        // Skip UI updates for quiet tools
        if (quiet_tools.has(tool_name)) {
            return;
        }

        // Stringify input JSON if present
        var input_str: ?[]const u8 = null;
        var input_owned: ?[]const u8 = null;
        defer if (input_owned) |owned| cb_ctx.handler.allocator.free(owned);
        if (input) |inp| {
            var out: std.io.Writer.Allocating = .init(cb_ctx.handler.allocator);
            defer out.deinit();
            var jw: std.json.Stringify = .{ .writer = &out.writer };
            jw.write(inp) catch {};
            input_owned = out.toOwnedSlice() catch null;
            input_str = input_owned;
        }

        try cb_ctx.handler.sendNotification("tool_call", protocol.ToolCall{
            .id = tool_id,
            .name = tool_name,
            .label = tool_label,
            .input = input_str,
        });
    }

    fn cbSendToolResult(ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_id: []const u8, content: ?[]const u8, status: ToolStatus, raw: ?std.json.Value) anyerror!void {
        _ = session_id;
        _ = engine;
        _ = raw;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        const status_str = switch (status) {
            .completed => "completed",
            .failed => "failed",
            .pending => "pending",
            .execute => "pending",
            .approved => "approved",
            .denied => "denied",
        };
        try cb_ctx.handler.sendNotification("tool_result", protocol.ToolResult{
            .id = tool_id,
            .status = status_str,
            .content = content,
        });
    }

    fn cbSendUserMessage(ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void {
        _ = session_id;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        try cb_ctx.handler.sendNotification("status", protocol.StatusUpdate{ .text = text });
    }

    fn cbOnTimeout(ctx: *anyopaque) void {
        // Poll thread handles WebSocket messages independently - nothing needed here
        _ = ctx;
    }

    fn cbOnSessionId(ctx: *anyopaque, engine: Engine, session_id: []const u8) void {
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        cb_ctx.handler.sendNotification("session_id", protocol.SessionIdUpdate{
            .engine = engine,
            .session_id = session_id,
        }) catch |err| {
            log.err("Failed to send session_id notification: {}", .{err});
        };
    }

    fn cbCheckAuthRequired(ctx: *anyopaque, session_id: []const u8, engine: Engine, content: []const u8) anyerror!?EditorCallbacks.StopReason {
        _ = session_id;
        _ = engine;
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));

        // Check if content indicates auth is required
        if (std.mem.indexOf(u8, content, "/login") != null or
            std.mem.indexOf(u8, content, "authenticate") != null)
        {
            cb_ctx.handler.sendNotification("error_msg", protocol.ErrorMessage{
                .message = "Authentication required. Please run `claude /login` in your terminal, then try again.",
            }) catch {};
            return .auth_required;
        }
        return null;
    }

    fn cbSendContinuePrompt(ctx: *anyopaque, engine: Engine, prompt: []const u8) anyerror!bool {
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        const handler = cb_ctx.handler;

        // Queue continuation prompt to be processed after current prompt completes
        if (handler.pending_continuation) |old| {
            handler.allocator.free(old.text);
        }
        handler.pending_continuation = .{
            .text = handler.allocator.dupe(u8, prompt) catch return false,
            .engine = engine,
        };
        log.info("Queued continuation prompt for {s}", .{@tagName(engine)});
        return true;
    }

    fn cbOnApprovalRequest(ctx: *anyopaque, request_id: std.json.Value, kind: ApprovalKind, params: ?std.json.Value) anyerror!?[]const u8 {
        const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx));
        const handler = cb_ctx.handler;

        // Convert request_id to string
        var id_buf: [64]u8 = undefined;
        const id_str = switch (request_id) {
            .integer => |i| std.fmt.bufPrint(&id_buf, "{d}", .{i}) catch "unknown",
            .string => |s| s,
            else => "unknown",
        };

        // Store pending approval ID
        if (handler.pending_approval_id) |old| {
            handler.allocator.free(old);
        }
        handler.pending_approval_id = handler.allocator.dupe(u8, id_str) catch return null;
        handler.pending_approval_response = null;

        // Convert kind to risk level
        const risk_level: []const u8 = switch (kind) {
            .command_execution, .exec_command => "high",
            .file_change, .apply_patch => "medium",
        };

        // Convert params to arguments string
        var args_str: ?[]const u8 = null;
        if (params) |p| {
            var out: std.io.Writer.Allocating = .init(handler.allocator);
            defer out.deinit();
            var jw: std.json.Stringify = .{
                .writer = &out.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            jw.write(p) catch {};
            args_str = out.toOwnedSlice() catch null;
        }
        defer if (args_str) |a| handler.allocator.free(a);

        // Get tool name from kind
        const tool_name: []const u8 = switch (kind) {
            .command_execution => "command_execution",
            .exec_command => "exec_command",
            .file_change => "file_change",
            .apply_patch => "apply_patch",
        };

        // Send approval request notification
        handler.sendNotification("approval_request", protocol.ApprovalRequest{
            .id = id_str,
            .tool_name = tool_name,
            .arguments = args_str,
            .risk_level = risk_level,
        }) catch |err| {
            log.err("Failed to send approval_request: {}", .{err});
            return null;
        };

        // Poll for response with 30 second timeout
        const timeout_ms: i64 = 30_000;
        const start_time = std.time.milliTimestamp();

        while (std.time.milliTimestamp() - start_time < timeout_ms) {
            // Check if cancelled
            if (handler.cancelled.load(.acquire)) {
                return "decline";
            }

            // Check if we have a response
            if (handler.pending_approval_response) |response| {
                // Clean up pending state
                if (handler.pending_approval_id) |pid| {
                    handler.allocator.free(pid);
                    handler.pending_approval_id = null;
                }

                // Return owned copy (caller doesn't free, but we need to keep it valid)
                // The response is already allocated, just return it and don't free
                const result = response;
                handler.pending_approval_response = null;
                return result;
            }

            // Poll MCP server for incoming messages
            if (handler.mcp_server) |mcp| {
                _ = mcp.poll(100) catch |err| {
                    log.warn("MCP poll error during approval wait: {}", .{err});
                };
            } else {
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        // Timeout - clean up and decline
        log.warn("Approval request timed out for {s}", .{id_str});
        if (handler.pending_approval_id) |pid| {
            handler.allocator.free(pid);
            handler.pending_approval_id = null;
        }
        return "decline";
    }
};

test "handler init/deinit" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(!handler.cancelled.load(.acquire));
    try std.testing.expect(handler.nudge_enabled);
}

test "handler nudge toggle" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(handler.nudge_enabled);

    // Toggle nudge (simulate callback)
    handler.nudge_enabled = !handler.nudge_enabled;
    try std.testing.expect(!handler.nudge_enabled);

    // Toggle again
    handler.nudge_enabled = !handler.nudge_enabled;
    try std.testing.expect(handler.nudge_enabled);
}

test "handler cancel" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    try std.testing.expect(!handler.cancelled.load(.acquire));

    // Cancel (simulate callback)
    handler.cancelled.store(true, .release);
    try std.testing.expect(handler.cancelled.load(.acquire));
}

test "cancelled flag is atomic - concurrent reads" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    // Spawn multiple reader threads
    const num_readers = 4;
    var readers: [num_readers]std.Thread = undefined;
    var read_counts: [num_readers]u32 = .{0} ** num_readers;

    for (0..num_readers) |i| {
        readers[i] = try std.Thread.spawn(.{}, struct {
            fn run(h: *Handler, count: *u32) void {
                // Read cancelled flag many times
                var local_count: u32 = 0;
                for (0..10000) |_| {
                    _ = h.cancelled.load(.acquire);
                    local_count += 1;
                }
                count.* = local_count;
            }
        }.run, .{ &handler, &read_counts[i] });
    }

    // Toggle cancelled while readers are running
    for (0..1000) |_| {
        handler.cancelled.store(true, .release);
        handler.cancelled.store(false, .release);
    }

    // Wait for all readers
    for (0..num_readers) |i| {
        readers[i].join();
        try std.testing.expectEqual(@as(u32, 10000), read_counts[i]);
    }
}

test "cancelled flag is atomic - writer thread sets, reader sees it" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    var seen_true = std.atomic.Value(bool).init(false);

    // Reader thread waits for cancelled to become true
    const reader = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, seen: *std.atomic.Value(bool)) void {
            const start = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - start < 1000) {
                if (h.cancelled.load(.acquire)) {
                    seen.store(true, .release);
                    return;
                }
                std.Thread.yield() catch {};
            }
        }
    }.run, .{ &handler, &seen_true });

    // Small delay then set cancelled
    std.Thread.sleep(10 * std.time.ns_per_ms);
    handler.cancelled.store(true, .release);

    reader.join();

    // Reader should have seen the cancelled flag
    try std.testing.expect(seen_true.load(.acquire));
}

test "should_exit flag stops poll thread" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    // Simulate what run() does - spawn poll thread
    var thread_exited = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, exited: *std.atomic.Value(bool)) void {
            while (!h.should_exit.load(.acquire)) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            exited.store(true, .release);
        }
    }.run, .{ &handler, &thread_exited });

    // Verify thread is running
    try std.testing.expect(!thread_exited.load(.acquire));

    // Signal exit
    handler.should_exit.store(true, .release);

    // Wait for thread with timeout
    thread.join();

    // Thread should have exited
    try std.testing.expect(thread_exited.load(.acquire));

    // Now safe to deinit (thread already joined)
    handler.deinit();
}

test "prompt queueing - main thread sees queued prompt" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    // Simulate what handleNvimPrompt does - queue a prompt
    const text = try allocator.dupe(u8, "test prompt");
    handler.prompt_mutex.lock();
    handler.pending_prompt = .{ .text = text, .cwd = null };
    handler.prompt_mutex.unlock();
    handler.prompt_ready.signal();

    // Verify prompt is queued
    handler.prompt_mutex.lock();
    try std.testing.expect(handler.pending_prompt != null);
    try std.testing.expectEqualStrings("test prompt", handler.pending_prompt.?.text);
    handler.prompt_mutex.unlock();

    // Clean up
    handler.should_exit.store(true, .release);
    handler.deinit();
}

test "cancel flag visible across threads during simulated processing" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    var processing_saw_cancel = std.atomic.Value(bool).init(false);
    var processing_started = std.atomic.Value(bool).init(false);

    // Simulate main thread processing a prompt
    const processor = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, started: *std.atomic.Value(bool), saw_cancel: *std.atomic.Value(bool)) void {
            started.store(true, .release);
            // Simulate polling for cancel during processing
            const start = std.time.milliTimestamp();
            while (std.time.milliTimestamp() - start < 1000) {
                if (h.cancelled.load(.acquire)) {
                    saw_cancel.store(true, .release);
                    return;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
    }.run, .{ &handler, &processing_started, &processing_saw_cancel });

    // Wait for processing to start
    while (!processing_started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    // Simulate poll thread receiving cancel (like handleNvimCancel)
    std.Thread.sleep(50 * std.time.ns_per_ms);
    handler.cancelled.store(true, .release);

    processor.join();

    // Verify processing saw the cancel
    try std.testing.expect(processing_saw_cancel.load(.acquire));

    handler.deinit();
}

test "prompt queue with condition variable wakeup" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    var waiter_got_prompt = std.atomic.Value(bool).init(false);

    // Simulate main thread waiting for prompt
    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(h: *Handler, got_prompt: *std.atomic.Value(bool)) void {
            h.prompt_mutex.lock();
            // Wait with timeout
            const start = std.time.milliTimestamp();
            while (h.pending_prompt == null and std.time.milliTimestamp() - start < 1000) {
                h.prompt_ready.timedWait(&h.prompt_mutex, 100 * std.time.ns_per_ms) catch {};
            }
            if (h.pending_prompt != null) {
                got_prompt.store(true, .release);
            }
            h.prompt_mutex.unlock();
        }
    }.run, .{ &handler, &waiter_got_prompt });

    // Small delay then queue prompt
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const text = try allocator.dupe(u8, "queued prompt");
    handler.prompt_mutex.lock();
    handler.pending_prompt = .{ .text = text, .cwd = null };
    handler.prompt_mutex.unlock();
    handler.prompt_ready.signal();

    waiter.join();

    // Verify waiter got the prompt
    try std.testing.expect(waiter_got_prompt.load(.acquire));

    handler.deinit();
}

test "protocol JsonRpcRequest parse" {
    const allocator = std.testing.allocator;

    const input =
        \\{"jsonrpc":"2.0","method":"prompt","params":{"text":"hello"},"id":1}
    ;

    var parsed = try std.json.parseFromSlice(protocol.JsonRpcRequest, allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("prompt", parsed.value.method);
    try std.testing.expect(parsed.value.params != null);
}

test "protocol PromptRequest parse" {
    const allocator = std.testing.allocator;

    const input =
        \\{"text":"hello world","cwd":"/tmp"}
    ;

    var parsed = try std.json.parseFromSlice(protocol.PromptRequest, allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello world", parsed.value.text);
    try std.testing.expect(parsed.value.cwd != null);
    try std.testing.expectEqualStrings("/tmp", parsed.value.cwd.?);
}

test "protocol StreamChunk serialization" {
    const allocator = std.testing.allocator;

    const chunk = protocol.StreamChunk{
        .text = "Hello",
        .is_thought = true,
    };

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try jw.write(chunk);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"is_thought\":true") != null);
}

test "generateSessionId format" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    const session_id = try handler.generateSessionId();
    defer allocator.free(session_id);

    // Format: "nvim-{32 hex chars}"
    try std.testing.expect(std.mem.startsWith(u8, session_id, "nvim-"));
    try std.testing.expectEqual(@as(usize, 37), session_id.len); // "nvim-" (5) + 32 hex chars

    // Verify hex chars are valid
    for (session_id[5..]) |c| {
        try std.testing.expect(std.ascii.isHex(c));
    }
}

test "generateSessionId uniqueness" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    const id1 = try handler.generateSessionId();
    defer allocator.free(id1);
    const id2 = try handler.generateSessionId();
    defer allocator.free(id2);

    // Two calls should produce different IDs
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

test "permission socket create and close" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());

    // Create socket
    try handler.createPermissionSocket();

    // Verify socket was created
    try std.testing.expect(handler.permission_socket != null);
    try std.testing.expect(handler.permission_socket_path != null);
    try std.testing.expect(handler.nvim_session_id != null);

    // Socket path should match session ID
    try std.testing.expect(std.mem.indexOf(u8, handler.permission_socket_path.?, handler.nvim_session_id.?) != null);

    // Socket file should exist
    const stat = std.fs.cwd().statFile(handler.permission_socket_path.?) catch null;
    try std.testing.expect(stat != null);

    // Close socket
    handler.closePermissionSocket();

    // Verify cleanup
    try std.testing.expect(handler.permission_socket == null);
    try std.testing.expect(handler.permission_socket_path == null);

    handler.deinit();
}

test "checkPermissionAutoApprove safe tools" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    // Safe tools should always be approved
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Read").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Glob").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Grep").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("TodoWrite").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Task").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("LSP").?);

    // Dangerous tools should NOT be auto-approved in default mode
    try std.testing.expect(handler.checkPermissionAutoApprove("Bash") == null);
    try std.testing.expect(handler.checkPermissionAutoApprove("Write") == null);
    try std.testing.expect(handler.checkPermissionAutoApprove("Edit") == null);
}

test "checkPermissionAutoApprove auto_approve mode" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    // Set auto_approve mode
    handler.permission_mode = .auto_approve;

    // All tools should be approved
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Bash").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Write").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Edit").?);
}

test "checkPermissionAutoApprove accept_edits mode" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    // Set accept_edits mode
    handler.permission_mode = .accept_edits;

    // Edit tools should be approved
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Write").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Edit").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("MultiEdit").?);
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("NotebookEdit").?);

    // Bash should NOT be auto-approved in accept_edits mode
    try std.testing.expect(handler.checkPermissionAutoApprove("Bash") == null);
}

test "checkPermissionAutoApprove always_allowed_tools" {
    const allocator = std.testing.allocator;

    var stdin_buf: [0]u8 = undefined;
    var stdout_buf: [1024]u8 = undefined;
    var stdin = std.io.fixedBufferStream(&stdin_buf);
    var stdout = std.io.fixedBufferStream(&stdout_buf);

    var handler = Handler.init(allocator, stdin.reader().any(), stdout.writer().any());
    defer handler.deinit();

    // Bash normally requires permission
    try std.testing.expect(handler.checkPermissionAutoApprove("Bash") == null);

    // Add to always_allowed_tools (simulates "Allow Always" selection)
    try handler.always_allowed_tools.put("Bash", {});

    // Now Bash should be approved
    try std.testing.expectEqualStrings("allow", handler.checkPermissionAutoApprove("Bash").?);
}

test "protocol PermissionResponseRequest parse" {
    const allocator = std.testing.allocator;

    const input =
        \\{"id":"perm-123","decision":"allow_always"}
    ;

    var parsed = try std.json.parseFromSlice(protocol.PermissionResponseRequest, allocator, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("perm-123", parsed.value.id);
    try std.testing.expectEqualStrings("allow_always", parsed.value.decision);
}
