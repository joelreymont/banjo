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

const SettingsFile = struct {
    allowedTools: ?[]const []const u8 = null,
    disallowedTools: ?[]const []const u8 = null,
    hooks: ?Hooks = null,
};

const Hooks = struct {
    PreToolUse: ?[]const []const u8 = null,
    PostToolUse: ?[]const []const u8 = null,
};

/// Load settings from .claude/settings.json in the given directory
pub fn loadSettings(allocator: Allocator, cwd: []const u8) !Settings {
    var settings = Settings.init(allocator);
    errdefer settings.deinit();

    // Try to read settings file
    const settings_path = try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
    defer allocator.free(settings_path);

    // Use cwd().openFile to handle both absolute and relative paths
    const file = std.fs.cwd().openFile(settings_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("No settings file at {s}", .{settings_path});
            return settings;
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(SettingsFile, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.allowedTools) |allowed| {
        for (allowed) |tool_name| {
            const tool = try allocator.dupe(u8, tool_name);
            try settings.allowed_tools.put(tool, {});
        }
    }

    if (parsed.value.disallowedTools) |denied| {
        for (denied) |tool_name| {
            const tool = try allocator.dupe(u8, tool_name);
            try settings.denied_tools.put(tool, {});
        }
    }

    if (parsed.value.hooks) |hooks| {
        if (hooks.PreToolUse) |pre| {
            for (pre) |hook_cmd| {
                const hook = try allocator.dupe(u8, hook_cmd);
                try settings.pre_hooks.append(allocator, hook);
            }
        }
        if (hooks.PostToolUse) |post| {
            for (post) |hook_cmd| {
                const hook = try allocator.dupe(u8, hook_cmd);
                try settings.post_hooks.append(allocator, hook);
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

// =============================================================================
// Property Tests for Settings Permissions
// =============================================================================

const quickcheck = @import("../util/quickcheck.zig");

/// Tool name options for property tests (avoids generating slices)
const test_tools = [_][]const u8{ "Read", "Write", "Bash", "Edit", "Grep", "Glob", "WebFetch" };

fn getTestTool(idx: u3) []const u8 {
    return test_tools[@min(idx, test_tools.len - 1)];
}

test "property: isAllowed returns true only for added tools" {
    try quickcheck.check(struct {
        fn prop(args: struct { add_idx: u3, check_idx: u3 }) bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const add_tool = getTestTool(args.add_idx);
            const check_tool = getTestTool(args.check_idx);

            // Add the tool
            const owned = testing.allocator.dupe(u8, add_tool) catch return false;
            settings.allowed_tools.put(owned, {}) catch {
                testing.allocator.free(owned);
                return false;
            };

            // Check: should be allowed only if same tool
            const is_allowed = settings.isAllowed(check_tool);
            const should_be_allowed = std.mem.eql(u8, add_tool, check_tool);
            return is_allowed == should_be_allowed;
        }
    }.prop, .{});
}

test "property: isDenied returns true only for added tools" {
    try quickcheck.check(struct {
        fn prop(args: struct { add_idx: u3, check_idx: u3 }) bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const add_tool = getTestTool(args.add_idx);
            const check_tool = getTestTool(args.check_idx);

            // Add to denied
            const owned = testing.allocator.dupe(u8, add_tool) catch return false;
            settings.denied_tools.put(owned, {}) catch {
                testing.allocator.free(owned);
                return false;
            };

            // Check: should be denied only if same tool
            const is_denied = settings.isDenied(check_tool);
            const should_be_denied = std.mem.eql(u8, add_tool, check_tool);
            return is_denied == should_be_denied;
        }
    }.prop, .{});
}

test "property: allowed and denied are independent" {
    try quickcheck.check(struct {
        fn prop(args: struct { allow_idx: u3, deny_idx: u3, check_idx: u3 }) bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const allow_tool = getTestTool(args.allow_idx);
            const deny_tool = getTestTool(args.deny_idx);
            const check_tool = getTestTool(args.check_idx);

            // Add to allowed
            const owned_allow = testing.allocator.dupe(u8, allow_tool) catch return false;
            settings.allowed_tools.put(owned_allow, {}) catch {
                testing.allocator.free(owned_allow);
                return false;
            };

            // Add to denied
            const owned_deny = testing.allocator.dupe(u8, deny_tool) catch return false;
            settings.denied_tools.put(owned_deny, {}) catch {
                testing.allocator.free(owned_deny);
                return false;
            };

            // isAllowed and isDenied should be independent checks
            const is_allowed = settings.isAllowed(check_tool);
            const is_denied = settings.isDenied(check_tool);

            const expect_allowed = std.mem.eql(u8, allow_tool, check_tool);
            const expect_denied = std.mem.eql(u8, deny_tool, check_tool);

            return is_allowed == expect_allowed and is_denied == expect_denied;
        }
    }.prop, .{});
}

test "property: empty settings allows/denies nothing" {
    try quickcheck.check(struct {
        fn prop(args: struct { tool_idx: u3 }) bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const tool = getTestTool(args.tool_idx);
            return !settings.isAllowed(tool) and !settings.isDenied(tool);
        }
    }.prop, .{});
}

test "property: multiple tools can be allowed/denied" {
    try quickcheck.check(struct {
        fn prop(args: struct { num_allowed: u2, num_denied: u2 }) bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            // Add some allowed tools
            for (0..args.num_allowed) |i| {
                const tool = test_tools[i % test_tools.len];
                const owned = testing.allocator.dupe(u8, tool) catch return false;
                settings.allowed_tools.put(owned, {}) catch {
                    testing.allocator.free(owned);
                    return false;
                };
            }

            // Add some denied tools (from the other end)
            for (0..args.num_denied) |i| {
                const tool = test_tools[(test_tools.len - 1 - i) % test_tools.len];
                const owned = testing.allocator.dupe(u8, tool) catch return false;
                settings.denied_tools.put(owned, {}) catch {
                    testing.allocator.free(owned);
                    return false;
                };
            }

            // Counts should match (accounting for potential duplicates in put)
            return settings.allowed_tools.count() <= args.num_allowed and
                settings.denied_tools.count() <= args.num_denied;
        }
    }.prop, .{});
}
