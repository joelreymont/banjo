const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.settings);

/// Result of ensuring hook is configured
pub const HookConfigResult = enum {
    already_configured,
    configured,
    failed,
};

/// Ensure the Banjo permission hook is configured in ~/.claude/settings.json
/// Returns whether it was newly configured (user needs to restart Claude Code)
pub fn ensurePermissionHook(allocator: Allocator) HookConfigResult {
    const home = std.posix.getenv("HOME") orelse return .failed;
    return ensurePermissionHookInDir(allocator, home);
}

/// Internal: ensure hook in specified home directory (for testing)
fn ensurePermissionHookInDir(allocator: Allocator, home: []const u8) HookConfigResult {
    // Use arena for all JSON allocations - cleaned up on return
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const settings_path = std.fs.path.join(aa, &.{ home, ".claude", "settings.json" }) catch return .failed;

    // Read existing file or start with empty object
    var root: std.json.Value = blk: {
        const file = std.fs.cwd().openFile(settings_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk .{ .object = std.json.ObjectMap.init(aa) },
            else => return .failed,
        };
        defer file.close();
        const content = file.readToEndAlloc(aa, 1024 * 1024) catch return .failed;
        const parsed = std.json.parseFromSlice(std.json.Value, aa, content, .{}) catch return .failed;
        break :blk parsed.value;
    };

    const obj = switch (root) {
        .object => |*o| o,
        else => return .failed,
    };

    // Get or create hooks object
    const hooks = if (obj.getPtr("hooks")) |h| switch (h.*) {
        .object => |*ho| ho,
        else => return .failed,
    } else blk: {
        const hooks_obj = std.json.ObjectMap.init(aa);
        obj.put("hooks", .{ .object = hooks_obj }) catch return .failed;
        break :blk &obj.getPtr("hooks").?.object;
    };

    // Check if PreToolUse already has our hook
    // NOTE: Using raw JSON navigation here (not typed structs) to preserve unknown fields
    // in the user's settings.json when we modify it. Typed parsing would lose user's custom settings.
    // PreToolUse is used instead of PermissionRequest because PermissionRequest only fires
    // when a permission dialog is shown - but in SDK/API mode there's no dialog.
    if (hooks.get("PreToolUse")) |pr| {
        if (pr == .array) {
            for (pr.array.items) |item| {
                if (item == .object) {
                    if (item.object.get("hooks")) |item_hooks| {
                        if (item_hooks == .array) {
                            for (item_hooks.array.items) |hook| {
                                if (hook == .object) {
                                    if (hook.object.get("command")) |cmd| {
                                        if (cmd == .string and std.mem.indexOf(u8, cmd.string, "banjo hook permission") != null) {
                                            return .already_configured;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Build new hook entry: {"hooks": [{"type": "command", "command": "banjo hook permission"}]}
    var hook_cmd = std.json.ObjectMap.init(aa);
    hook_cmd.put("type", .{ .string = "command" }) catch return .failed;
    hook_cmd.put("command", .{ .string = "banjo hook permission" }) catch return .failed;

    var hooks_array = std.json.Array.init(aa);
    hooks_array.append(.{ .object = hook_cmd }) catch return .failed;

    var entry = std.json.ObjectMap.init(aa);
    entry.put("hooks", .{ .array = hooks_array }) catch return .failed;

    // Get or create PreToolUse array
    const pr_array = if (hooks.getPtr("PreToolUse")) |pr| switch (pr.*) {
        .array => |*a| a,
        else => return .failed,
    } else blk: {
        const arr = std.json.Array.init(aa);
        hooks.put("PreToolUse", .{ .array = arr }) catch return .failed;
        break :blk &hooks.getPtr("PreToolUse").?.array;
    };

    // Add our hook entry
    pr_array.append(.{ .object = entry }) catch return .failed;

    // Ensure ~/.claude directory exists
    const claude_dir = std.fs.path.join(aa, &.{ home, ".claude" }) catch return .failed;
    std.fs.cwd().makePath(claude_dir) catch |err| {
        log.warn("Failed to create Claude settings dir {s}: {}", .{ claude_dir, err });
        return .failed;
    };

    // Write back with pretty-printing
    const json = std.json.Stringify.valueAlloc(aa, root, .{
        .whitespace = .indent_2,
    }) catch return .failed;

    const file = std.fs.cwd().createFile(settings_path, .{}) catch return .failed;
    defer file.close();
    file.writeAll(json) catch return .failed;
    file.writeAll("\n") catch return .failed;

    log.info("Configured Banjo permission hook in {s}", .{settings_path});
    return .configured;
}

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
const ohsnap = @import("ohsnap");

test "Settings init/deinit" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("allowed: {any}\ndenied: {any}\n", .{
        settings.isAllowed("test"),
        settings.isDenied("test"),
    });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\allowed: false
        \\denied: false
        \\
    ).diff(snapshot, true);
}

// =============================================================================
// Property Tests for Settings Permissions
// =============================================================================

const zcheck = @import("zcheck");
const zcheck_seed_base: u64 = 0x4b19_7f6d_a803_2e11;

/// Tool name options for property tests (avoids generating slices)
const test_tools = [_][]const u8{ "Read", "Write", "Bash", "Edit", "Grep", "Glob", "WebFetch" };

fn getTestTool(idx: u3) []const u8 {
    return test_tools[@min(idx, test_tools.len - 1)];
}

test "property: isAllowed returns true only for added tools" {
    try zcheck.check(struct {
        fn prop(args: struct { add_idx: u3, check_idx: u3 }) !bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const add_tool = getTestTool(args.add_idx);
            const check_tool = getTestTool(args.check_idx);

            // Add the tool
            const owned = try testing.allocator.dupe(u8, add_tool);
            errdefer testing.allocator.free(owned);
            try settings.allowed_tools.put(owned, {});

            // Check: should be allowed only if same tool
            const is_allowed = settings.isAllowed(check_tool);
            const should_be_allowed = std.mem.eql(u8, add_tool, check_tool);
            return is_allowed == should_be_allowed;
        }
    }.prop, .{ .seed = zcheck_seed_base + 1 });
}

test "property: isDenied returns true only for added tools" {
    try zcheck.check(struct {
        fn prop(args: struct { add_idx: u3, check_idx: u3 }) !bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const add_tool = getTestTool(args.add_idx);
            const check_tool = getTestTool(args.check_idx);

            // Add to denied
            const owned = try testing.allocator.dupe(u8, add_tool);
            errdefer testing.allocator.free(owned);
            try settings.denied_tools.put(owned, {});

            // Check: should be denied only if same tool
            const is_denied = settings.isDenied(check_tool);
            const should_be_denied = std.mem.eql(u8, add_tool, check_tool);
            return is_denied == should_be_denied;
        }
    }.prop, .{ .seed = zcheck_seed_base + 2 });
}

test "property: allowed and denied are independent" {
    try zcheck.check(struct {
        fn prop(args: struct { allow_idx: u3, deny_idx: u3, check_idx: u3 }) !bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const allow_tool = getTestTool(args.allow_idx);
            const deny_tool = getTestTool(args.deny_idx);
            const check_tool = getTestTool(args.check_idx);

            // Add to allowed
            const owned_allow = try testing.allocator.dupe(u8, allow_tool);
            errdefer testing.allocator.free(owned_allow);
            try settings.allowed_tools.put(owned_allow, {});

            // Add to denied
            const owned_deny = try testing.allocator.dupe(u8, deny_tool);
            errdefer testing.allocator.free(owned_deny);
            try settings.denied_tools.put(owned_deny, {});

            // isAllowed and isDenied should be independent checks
            const is_allowed = settings.isAllowed(check_tool);
            const is_denied = settings.isDenied(check_tool);

            const expect_allowed = std.mem.eql(u8, allow_tool, check_tool);
            const expect_denied = std.mem.eql(u8, deny_tool, check_tool);

            return is_allowed == expect_allowed and is_denied == expect_denied;
        }
    }.prop, .{ .seed = zcheck_seed_base + 3 });
}

test "property: empty settings allows/denies nothing" {
    try zcheck.check(struct {
        fn prop(args: struct { tool_idx: u3 }) bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            const tool = getTestTool(args.tool_idx);
            return !settings.isAllowed(tool) and !settings.isDenied(tool);
        }
    }.prop, .{ .seed = zcheck_seed_base + 4 });
}

test "property: multiple tools can be allowed/denied" {
    try zcheck.check(struct {
        fn prop(args: struct { num_allowed: u2, num_denied: u2 }) !bool {
            var settings = Settings.init(testing.allocator);
            defer settings.deinit();

            // Add some allowed tools
            for (0..args.num_allowed) |i| {
                const tool = test_tools[i % test_tools.len];
                const owned = try testing.allocator.dupe(u8, tool);
                errdefer testing.allocator.free(owned);
                try settings.allowed_tools.put(owned, {});
            }

            // Add some denied tools (from the other end)
            for (0..args.num_denied) |i| {
                const tool = test_tools[(test_tools.len - 1 - i) % test_tools.len];
                const owned = try testing.allocator.dupe(u8, tool);
                errdefer testing.allocator.free(owned);
                try settings.denied_tools.put(owned, {});
            }

            // Counts should match (accounting for potential duplicates in put)
            return settings.allowed_tools.count() <= args.num_allowed and
                settings.denied_tools.count() <= args.num_denied;
        }
    }.prop, .{ .seed = zcheck_seed_base + 5 });
}

test "ensurePermissionHook with temp directory" {
    // Create temp directory to act as HOME
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create .claude subdirectory
    tmp_dir.dir.makePath(".claude") catch |err| {
        log.err("Failed to create .claude: {}", .{err});
        return err;
    };

    // Write initial settings file
    const initial = "{\"model\": \"opus\", \"hooks\": {}}";
    const settings_file = try tmp_dir.dir.createFile(".claude/settings.json", .{});
    try settings_file.writeAll(initial);
    settings_file.close();

    // Get path to temp dir
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);

    // Test ensurePermissionHookInDir (new helper we'll add)
    const result = try ensurePermissionHookInDir(testing.allocator, tmp_path);

    // Verify file was updated
    const updated_file = try tmp_dir.dir.openFile(".claude/settings.json", .{});
    defer updated_file.close();
    const content = try updated_file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);
    const result2 = try ensurePermissionHookInDir(testing.allocator, tmp_path);
    const has_hook = std.mem.indexOf(u8, content, "banjo hook permission") != null;
    const has_pre = std.mem.indexOf(u8, content, "PreToolUse") != null;

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("first: {s}\nsecond: {s}\nhas_hook: {any}\nhas_pre: {any}\n", .{
        @tagName(result),
        @tagName(result2),
        has_hook,
        has_pre,
    });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\first: configured
        \\second: already_configured
        \\has_hook: true
        \\has_pre: true
        \\
    ).diff(snapshot, true);
}
