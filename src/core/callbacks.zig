const std = @import("std");
const types = @import("types.zig");
const tool_categories = @import("tool_categories.zig");
const Engine = types.Engine;

pub const ToolStatus = enum {
    pending,
    execute,
    approved,
    denied,
    completed,
    failed,
};

pub const ToolKind = tool_categories.ToolKind;

/// Codex approval request kind
pub const ApprovalKind = enum {
    command_execution,
    exec_command,
    file_change,
    apply_patch,
};

pub const EditorCallbacks = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Output callbacks
        sendText: *const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void,
        sendTextRaw: *const fn (ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void,
        sendTextPrefix: *const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void,
        sendThought: *const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine, text: []const u8) anyerror!void,
        sendThoughtRaw: *const fn (ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void,
        sendThoughtPrefix: *const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine) anyerror!void,
        sendToolCall: *const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_name: []const u8, tool_label: []const u8, tool_id: []const u8, kind: ToolKind, input: ?std.json.Value) anyerror!void,
        sendToolResult: *const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine, tool_id: []const u8, content: ?[]const u8, status: ToolStatus, raw: ?std.json.Value) anyerror!void,
        sendUserMessage: *const fn (ctx: *anyopaque, session_id: []const u8, text: []const u8) anyerror!void,

        // Event hooks
        onTimeout: *const fn (ctx: *anyopaque) void,
        onSessionId: *const fn (ctx: *anyopaque, engine: Engine, session_id: []const u8) void,
        onSlashCommands: ?*const fn (ctx: *anyopaque, session_id: []const u8, commands: []const []const u8) anyerror!void,
        checkAuthRequired: ?*const fn (ctx: *anyopaque, session_id: []const u8, engine: Engine, content: []const u8) anyerror!?StopReason,

        // Continue prompt (for nudge with bridge restart capability)
        // Returns true if prompt was sent and loop should continue, false to break
        sendContinuePrompt: *const fn (ctx: *anyopaque, engine: Engine, prompt: []const u8) anyerror!bool,

        // Restart engine (for context reload - clears session)
        // Returns true if restart succeeded
        restartEngine: *const fn (ctx: *anyopaque, engine: Engine) bool,

        // Codex approval request handling
        // request_id is the raw JSON value (integer or string)
        // Returns decision string: "approve" or "decline", or null if not handled
        onApprovalRequest: ?*const fn (ctx: *anyopaque, request_id: std.json.Value, kind: ApprovalKind, params: ?std.json.Value) anyerror!?[]const u8,
    };

    pub const StopReason = enum {
        end_turn,
        cancelled,
        max_tokens,
        max_turn_requests,
        auth_required,
        context_reloaded, // Bridge was restarted, caller should re-invoke with new bridge
    };

    pub fn sendText(self: EditorCallbacks, session_id: []const u8, engine: Engine, text: []const u8) !void {
        return self.vtable.sendText(self.ctx, session_id, engine, text);
    }

    pub fn sendTextRaw(self: EditorCallbacks, session_id: []const u8, text: []const u8) !void {
        return self.vtable.sendTextRaw(self.ctx, session_id, text);
    }

    pub fn sendTextPrefix(self: EditorCallbacks, session_id: []const u8, engine: Engine) !void {
        return self.vtable.sendTextPrefix(self.ctx, session_id, engine);
    }

    pub fn sendThought(self: EditorCallbacks, session_id: []const u8, engine: Engine, text: []const u8) !void {
        return self.vtable.sendThought(self.ctx, session_id, engine, text);
    }

    pub fn sendThoughtRaw(self: EditorCallbacks, session_id: []const u8, text: []const u8) !void {
        return self.vtable.sendThoughtRaw(self.ctx, session_id, text);
    }

    pub fn sendThoughtPrefix(self: EditorCallbacks, session_id: []const u8, engine: Engine) !void {
        return self.vtable.sendThoughtPrefix(self.ctx, session_id, engine);
    }

    pub fn sendToolCall(self: EditorCallbacks, session_id: []const u8, engine: Engine, tool_name: []const u8, tool_label: []const u8, tool_id: []const u8, kind: ToolKind, input: ?std.json.Value) !void {
        return self.vtable.sendToolCall(self.ctx, session_id, engine, tool_name, tool_label, tool_id, kind, input);
    }

    pub fn sendToolResult(self: EditorCallbacks, session_id: []const u8, engine: Engine, tool_id: []const u8, content: ?[]const u8, status: ToolStatus, raw: ?std.json.Value) !void {
        return self.vtable.sendToolResult(self.ctx, session_id, engine, tool_id, content, status, raw);
    }

    pub fn sendUserMessage(self: EditorCallbacks, session_id: []const u8, text: []const u8) !void {
        return self.vtable.sendUserMessage(self.ctx, session_id, text);
    }

    pub fn onTimeout(self: EditorCallbacks) void {
        return self.vtable.onTimeout(self.ctx);
    }

    pub fn onSessionId(self: EditorCallbacks, engine: Engine, session_id: []const u8) void {
        return self.vtable.onSessionId(self.ctx, engine, session_id);
    }

    pub fn onSlashCommands(self: EditorCallbacks, session_id: []const u8, commands: []const []const u8) !void {
        if (self.vtable.onSlashCommands) |f| {
            return f(self.ctx, session_id, commands);
        }
    }

    pub fn checkAuthRequired(self: EditorCallbacks, session_id: []const u8, engine: Engine, content: []const u8) !?StopReason {
        if (self.vtable.checkAuthRequired) |f| {
            return f(self.ctx, session_id, engine, content);
        }
        return null;
    }

    pub fn sendContinuePrompt(self: EditorCallbacks, engine: Engine, prompt: []const u8) !bool {
        return self.vtable.sendContinuePrompt(self.ctx, engine, prompt);
    }

    pub fn restartEngine(self: EditorCallbacks, engine: Engine) bool {
        return self.vtable.restartEngine(self.ctx, engine);
    }

    pub fn onApprovalRequest(self: EditorCallbacks, request_id: std.json.Value, kind: ApprovalKind, params: ?std.json.Value) !?[]const u8 {
        if (self.vtable.onApprovalRequest) |f| {
            return f(self.ctx, request_id, kind, params);
        }
        return null;
    }
};

// Tests
const testing = std.testing;
const ohsnap = @import("ohsnap");

test "ToolStatus enum values" {
    const summary = .{
        .pending = @intFromEnum(ToolStatus.pending),
        .execute = @intFromEnum(ToolStatus.execute),
        .approved = @intFromEnum(ToolStatus.approved),
        .denied = @intFromEnum(ToolStatus.denied),
        .completed = @intFromEnum(ToolStatus.completed),
        .failed = @intFromEnum(ToolStatus.failed),
    };
    try (ohsnap{}).snap(@src(),
        \\core.callbacks.test.ToolStatus enum values__struct_<^\d+$>
        \\  .pending: u3 = 0
        \\  .execute: u3 = 1
        \\  .approved: u3 = 2
        \\  .denied: u3 = 3
        \\  .completed: u3 = 4
        \\  .failed: u3 = 5
    ).expectEqual(summary);
}

test "ToolKind enum values" {
    const summary = .{
        .read = @intFromEnum(ToolKind.read),
        .edit = @intFromEnum(ToolKind.edit),
        .execute = @intFromEnum(ToolKind.execute),
        .browser = @intFromEnum(ToolKind.browser),
        .other = @intFromEnum(ToolKind.other),
    };
    try (ohsnap{}).snap(@src(),
        \\core.callbacks.test.ToolKind enum values__struct_<^\d+$>
        \\  .read: u3 = 0
        \\  .edit: u3 = 1
        \\  .execute: u3 = 2
        \\  .browser: u3 = 3
        \\  .other: u3 = 4
    ).expectEqual(summary);
}

test "ApprovalKind enum values" {
    const summary = .{
        .command_execution = @intFromEnum(ApprovalKind.command_execution),
        .exec_command = @intFromEnum(ApprovalKind.exec_command),
        .file_change = @intFromEnum(ApprovalKind.file_change),
        .apply_patch = @intFromEnum(ApprovalKind.apply_patch),
    };
    try (ohsnap{}).snap(@src(),
        \\core.callbacks.test.ApprovalKind enum values__struct_<^\d+$>
        \\  .command_execution: u2 = 0
        \\  .exec_command: u2 = 1
        \\  .file_change: u2 = 2
        \\  .apply_patch: u2 = 3
    ).expectEqual(summary);
}

test "StopReason enum values" {
    const summary = .{
        .end_turn = @intFromEnum(EditorCallbacks.StopReason.end_turn),
        .cancelled = @intFromEnum(EditorCallbacks.StopReason.cancelled),
        .max_tokens = @intFromEnum(EditorCallbacks.StopReason.max_tokens),
        .max_turn_requests = @intFromEnum(EditorCallbacks.StopReason.max_turn_requests),
        .auth_required = @intFromEnum(EditorCallbacks.StopReason.auth_required),
        .context_reloaded = @intFromEnum(EditorCallbacks.StopReason.context_reloaded),
    };
    try (ohsnap{}).snap(@src(),
        \\core.callbacks.test.StopReason enum values__struct_<^\d+$>
        \\  .end_turn: u3 = 0
        \\  .cancelled: u3 = 1
        \\  .max_tokens: u3 = 2
        \\  .max_turn_requests: u3 = 3
        \\  .auth_required: u3 = 4
        \\  .context_reloaded: u3 = 5
    ).expectEqual(summary);
}

test "EditorCallbacks layout" {
    const summary = .{
        .size = @as(usize, @sizeOf(EditorCallbacks)),
        .alignment = @as(usize, @alignOf(EditorCallbacks)),
        .ctx_off = @as(usize, @offsetOf(EditorCallbacks, "ctx")),
        .vtable_off = @as(usize, @offsetOf(EditorCallbacks, "vtable")),
    };
    try (ohsnap{}).snap(@src(),
        \\core.callbacks.test.EditorCallbacks layout__struct_<^\d+$>
        \\  .size: usize = 16
        \\  .alignment: usize = 8
        \\  .ctx_off: usize = 0
        \\  .vtable_off: usize = 8
    ).expectEqual(summary);
}
