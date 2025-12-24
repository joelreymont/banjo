const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.settings);

/// Claude Code settings from .claude/settings.json
pub const Settings = struct {
    /// Tools that are always allowed
    allowed_tools: std.StringHashMap(void),
    /// Tools that are always denied
    denied_tools: std.StringHashMap(void),
    /// Pre-hook commands (run before tool execution)
    pre_hooks: std.ArrayList([]const u8),
    /// Post-hook commands (run after tool execution)
    post_hooks: std.ArrayList([]const u8),

    allocator: Allocator,

    pub fn init(allocator: Allocator) Settings {
        return .{
            .allowed_tools = std.StringHashMap(void).init(allocator),
            .denied_tools = std.StringHashMap(void).init(allocator),
            .pre_hooks = .empty,
            .post_hooks = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Settings) void {
        // Free owned strings
        var allowed_it = self.allowed_tools.keyIterator();
        while (allowed_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.allowed_tools.deinit();

        var denied_it = self.denied_tools.keyIterator();
        while (denied_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.denied_tools.deinit();

        for (self.pre_hooks.items) |hook| {
            self.allocator.free(hook);
        }
        self.pre_hooks.deinit(self.allocator);

        for (self.post_hooks.items) |hook| {
            self.allocator.free(hook);
        }
        self.post_hooks.deinit(self.allocator);
    }

    /// Check if a tool is explicitly allowed
    pub fn isAllowed(self: *const Settings, tool_name: []const u8) bool {
        return self.allowed_tools.contains(tool_name);
    }

    /// Check if a tool is explicitly denied
    pub fn isDenied(self: *const Settings, tool_name: []const u8) bool {
        return self.denied_tools.contains(tool_name);
    }
};

/// Load settings from .claude/settings.json in the given directory
pub fn loadSettings(allocator: Allocator, cwd: []const u8) !Settings {
    var settings = Settings.init(allocator);
    errdefer settings.deinit();

    // Try to read settings file
    const settings_path = try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
    defer allocator.free(settings_path);

    const file = std.fs.openFileAbsolute(settings_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("No settings file at {s}", .{settings_path});
            return settings;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return settings;
    const obj = parsed.value.object;

    // Parse allowedTools
    if (obj.get("allowedTools")) |allowed| {
        if (allowed == .array) {
            for (allowed.array.items) |item| {
                if (item == .string) {
                    const tool = try allocator.dupe(u8, item.string);
                    try settings.allowed_tools.put(tool, {});
                }
            }
        }
    }

    // Parse disallowedTools
    if (obj.get("disallowedTools")) |denied| {
        if (denied == .array) {
            for (denied.array.items) |item| {
                if (item == .string) {
                    const tool = try allocator.dupe(u8, item.string);
                    try settings.denied_tools.put(tool, {});
                }
            }
        }
    }

    // Parse hooks
    if (obj.get("hooks")) |hooks| {
        if (hooks == .object) {
            if (hooks.object.get("PreToolUse")) |pre| {
                if (pre == .array) {
                    for (pre.array.items) |item| {
                        if (item == .string) {
                            const hook = try allocator.dupe(u8, item.string);
                            try settings.pre_hooks.append(allocator, hook);
                        }
                    }
                }
            }
            if (hooks.object.get("PostToolUse")) |post| {
                if (post == .array) {
                    for (post.array.items) |item| {
                        if (item == .string) {
                            const hook = try allocator.dupe(u8, item.string);
                            try settings.post_hooks.append(allocator, hook);
                        }
                    }
                }
            }
        }
    }

    log.info("Loaded settings: {d} allowed, {d} denied, {d} pre-hooks, {d} post-hooks", .{
        settings.allowed_tools.count(),
        settings.denied_tools.count(),
        settings.pre_hooks.items.len,
        settings.post_hooks.items.len,
    });

    return settings;
}

// Tests
const testing = std.testing;

test "Settings init/deinit" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();

    try testing.expect(!settings.isAllowed("test"));
    try testing.expect(!settings.isDenied("test"));
}
