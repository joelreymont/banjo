const std = @import("std");
const protocol = @import("../acp/protocol.zig");

/// Unified tool kind for engine/callback layers
pub const ToolKind = enum {
    read,
    edit,
    execute,
    browser,
    other,

    /// Convert to protocol ToolKind for ACP SessionUpdate
    pub fn toProtocol(self: ToolKind) protocol.SessionUpdate.ToolKind {
        return switch (self) {
            .read => .read,
            .edit => .edit,
            .execute => .execute,
            .browser => .fetch,
            .other => .other,
        };
    }
};

/// Map tool name to ToolKind
const tool_kind_map = std.StaticStringMap(ToolKind).initComptime(.{
    .{ "Read", .read },
    .{ "Glob", .read },
    .{ "Grep", .read },
    .{ "LS", .read },
    .{ "Edit", .edit },
    .{ "Write", .edit },
    .{ "MultiEdit", .edit },
    .{ "NotebookEdit", .edit },
    .{ "Bash", .execute },
    .{ "Command", .execute },
    .{ "Task", .execute },
    .{ "WebFetch", .browser },
    .{ "WebSearch", .browser },
});

pub fn getToolKind(tool_name: []const u8) ToolKind {
    return tool_kind_map.get(tool_name) orelse .other;
}

/// Tool category flags
pub const ToolFlags = struct {
    safe: bool = false, // Auto-approve (no permission needed)
    edit: bool = false, // Edit tool (auto-approve in acceptEdits mode)
    quiet: bool = false, // No UI updates for tool calls
};

/// Master tool categorization table
const tool_flags = std.StaticStringMap(ToolFlags).initComptime(.{
    // Safe + Quiet tools (auto-approve, no UI)
    .{ "TodoWrite", ToolFlags{ .safe = true, .quiet = true } },
    .{ "TodoRead", ToolFlags{ .safe = true, .quiet = true } },
    .{ "TaskOutput", ToolFlags{ .safe = true, .quiet = true } },
    .{ "Read", ToolFlags{ .safe = true, .quiet = true } },
    .{ "Grep", ToolFlags{ .safe = true, .quiet = true } },
    .{ "Glob", ToolFlags{ .safe = true, .quiet = true } },
    .{ "LSP", ToolFlags{ .safe = true, .quiet = true } },

    // Safe tools (auto-approve, show in UI)
    .{ "Task", ToolFlags{ .safe = true } },
    .{ "AskUserQuestion", ToolFlags{ .safe = true } },

    // Edit + Quiet tools (auto-approve in acceptEdits, no UI)
    .{ "Write", ToolFlags{ .edit = true, .quiet = true } },
    .{ "Edit", ToolFlags{ .edit = true, .quiet = true } },
    .{ "MultiEdit", ToolFlags{ .edit = true, .quiet = true } },
    .{ "NotebookEdit", ToolFlags{ .edit = true, .quiet = true } },

    // Quiet-only tools (need permission, no UI)
    .{ "NotebookRead", ToolFlags{ .quiet = true } },
    .{ "Skill", ToolFlags{ .quiet = true } },
    .{ "KillShell", ToolFlags{ .quiet = true } },
    .{ "EnterPlanMode", ToolFlags{ .quiet = true } },
    .{ "ExitPlanMode", ToolFlags{ .quiet = true } },
});

/// Get flags for a tool, returns default (all false) if unknown
pub fn getFlags(tool_name: []const u8) ToolFlags {
    return tool_flags.get(tool_name) orelse .{};
}

/// Check if tool is safe (auto-approve)
pub fn isSafe(tool_name: []const u8) bool {
    return getFlags(tool_name).safe;
}

/// Check if tool is an edit tool
pub fn isEdit(tool_name: []const u8) bool {
    return getFlags(tool_name).edit;
}

/// Check if tool should be quiet (no UI updates)
pub fn isQuiet(tool_name: []const u8) bool {
    return getFlags(tool_name).quiet;
}

const ohsnap = @import("ohsnap");

test "tool kind mapping" {
    const summary = .{
        .read = getToolKind("Read"),
        .glob = getToolKind("Glob"),
        .edit = getToolKind("Edit"),
        .write = getToolKind("Write"),
        .bash = getToolKind("Bash"),
        .task = getToolKind("Task"),
        .webfetch = getToolKind("WebFetch"),
        .unknown = getToolKind("Unknown"),
    };
    try (ohsnap{}).snap(@src(),
        \\core.tool_categories.test.tool kind mapping__struct_<^\d+$>
        \\  .read: core.tool_categories.ToolKind
        \\    .read
        \\  .glob: core.tool_categories.ToolKind
        \\    .read
        \\  .edit: core.tool_categories.ToolKind
        \\    .edit
        \\  .write: core.tool_categories.ToolKind
        \\    .edit
        \\  .bash: core.tool_categories.ToolKind
        \\    .execute
        \\  .task: core.tool_categories.ToolKind
        \\    .execute
        \\  .webfetch: core.tool_categories.ToolKind
        \\    .browser
        \\  .unknown: core.tool_categories.ToolKind
        \\    .other
    ).expectEqual(summary);
}

test "tool kind to protocol" {
    const summary = .{
        .read = ToolKind.read.toProtocol(),
        .edit = ToolKind.edit.toProtocol(),
        .execute = ToolKind.execute.toProtocol(),
        .browser = ToolKind.browser.toProtocol(),
        .other = ToolKind.other.toProtocol(),
    };
    try (ohsnap{}).snap(@src(),
        \\core.tool_categories.test.tool kind to protocol__struct_<^\d+$>
        \\  .read: acp.protocol.SessionUpdate.ToolKind
        \\    .read
        \\  .edit: acp.protocol.SessionUpdate.ToolKind
        \\    .edit
        \\  .execute: acp.protocol.SessionUpdate.ToolKind
        \\    .execute
        \\  .browser: acp.protocol.SessionUpdate.ToolKind
        \\    .fetch
        \\  .other: acp.protocol.SessionUpdate.ToolKind
        \\    .other
    ).expectEqual(summary);
}

test "tool categories" {
    const summary = .{
        .safe_read = isSafe("Read"),
        .safe_todo = isSafe("TodoWrite"),
        .safe_bash = isSafe("Bash"),
        .safe_write = isSafe("Write"),
        .edit_write = isEdit("Write"),
        .edit_edit = isEdit("Edit"),
        .edit_read = isEdit("Read"),
        .edit_bash = isEdit("Bash"),
        .quiet_read = isQuiet("Read"),
        .quiet_write = isQuiet("Write"),
        .quiet_skill = isQuiet("Skill"),
        .quiet_bash = isQuiet("Bash"),
        .quiet_task = isQuiet("Task"),
    };
    try (ohsnap{}).snap(@src(),
        \\core.tool_categories.test.tool categories__struct_<^\d+$>
        \\  .safe_read: bool = true
        \\  .safe_todo: bool = true
        \\  .safe_bash: bool = false
        \\  .safe_write: bool = false
        \\  .edit_write: bool = true
        \\  .edit_edit: bool = true
        \\  .edit_read: bool = false
        \\  .edit_bash: bool = false
        \\  .quiet_read: bool = true
        \\  .quiet_write: bool = true
        \\  .quiet_skill: bool = true
        \\  .quiet_bash: bool = false
        \\  .quiet_task: bool = false
    ).expectEqual(summary);
}
