const std = @import("std");

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

test "tool categories" {
    // Safe tools
    try std.testing.expect(isSafe("Read"));
    try std.testing.expect(isSafe("TodoWrite"));
    try std.testing.expect(!isSafe("Bash"));
    try std.testing.expect(!isSafe("Write"));

    // Edit tools
    try std.testing.expect(isEdit("Write"));
    try std.testing.expect(isEdit("Edit"));
    try std.testing.expect(!isEdit("Read"));
    try std.testing.expect(!isEdit("Bash"));

    // Quiet tools
    try std.testing.expect(isQuiet("Read"));
    try std.testing.expect(isQuiet("Write"));
    try std.testing.expect(isQuiet("Skill"));
    try std.testing.expect(!isQuiet("Bash"));
    try std.testing.expect(!isQuiet("Task"));
}
