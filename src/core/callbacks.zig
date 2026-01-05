const std = @import("std");
const types = @import("types.zig");
const Engine = types.Engine;

pub const ToolStatus = enum {
    pending,
    execute,
    approved,
    denied,
    completed,
    failed,
};

pub const ToolKind = enum {
    read,
    edit,
    execute,
    browser,
    other,
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
    };

    pub const StopReason = enum {
        end_turn,
        cancelled,
        max_tokens,
        max_turn_requests,
        auth_required,
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
};
