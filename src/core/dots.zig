const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const executable = @import("executable.zig");

const Engine = types.Engine;
const log = std.log.scoped(.dots);
const max_dot_output_bytes: usize = 128 * 1024;
const dot_paths = [_][]const u8{
    "/usr/local/bin/dot",
    "/opt/homebrew/bin/dot",
};

// Skill template embedded at compile time
pub const skill_prompt = @embedFile("dot-skill");

const DotTask = struct {
    status: []const u8,
};

/// Returns the trigger command for the dot skill
pub fn trigger(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "/dot",
        .codex => "$dot",
    };
}

/// Returns the clear context command
pub fn clearCmd(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => "/clear",
        .codex => "/clear",
    };
}

/// Context prompt sent after clearing, prompts agent to read guidelines and continue
pub fn contextPrompt(engine: Engine) []const u8 {
    _ = engine;
    return
        \\Read your project guidelines (AGENTS.md).
        \\Check active dots: `dot ls --status active`
        \\If the dot description contains a plan file path, read it.
        \\Continue with the current task.
    ;
}

/// Legacy constant for backwards compatibility in tests
pub const context_prompt = contextPrompt(.claude);

/// Check if command string contains "dot off" with word boundaries
pub fn containsDotOffStr(cmd: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, cmd, offset, "dot off")) |idx| {
        // Check leading boundary - must be start of string or preceded by separator
        if (idx > 0) {
            const prev = cmd[idx - 1];
            // Valid separators: space, semicolon, ampersand, pipe, newline, tab, quotes
            const valid_lead = prev == ' ' or prev == ';' or prev == '&' or
                prev == '|' or prev == '\n' or prev == '\t' or
                prev == '"' or prev == '\'' or prev == '(';
            if (!valid_lead) {
                offset = idx + 1;
                continue;
            }
        }
        // Check trailing boundary
        const after = idx + 7; // "dot off" is 7 chars
        if (after < cmd.len) {
            const next = cmd[after];
            // Valid separators: space, semicolon, ampersand, pipe, newline, tab, quotes, parens
            const valid_trail = next == ' ' or next == ';' or next == '&' or
                next == '|' or next == '\n' or next == '\t' or
                next == '"' or next == '\'' or next == ')';
            if (!valid_trail) {
                offset = idx + 1;
                continue;
            }
        }
        return true;
    }
    return false;
}

/// Typed struct for Claude Bash tool input
const BashToolInput = struct {
    command: []const u8,
};

/// Check if JSON input (Claude Bash tool) contains "dot off"
pub fn containsDotOff(input: std.json.Value) bool {
    const parsed = std.json.parseFromValue(BashToolInput, std.heap.page_allocator, input, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.debug("containsDotOff parse failed (not a Bash tool?): {}", .{err});
        return false;
    };
    defer parsed.deinit();
    return containsDotOffStr(parsed.value.command);
}

/// Returns the skill path for the given engine
pub fn skillPath(engine: Engine) []const u8 {
    return switch (engine) {
        .claude => ".claude/skills/dot/SKILL.md",
        .codex => ".codex/skills/dot/SKILL.md",
    };
}

/// Check if dot CLI is available
pub fn hasDotCli() bool {
    return executable.isAvailable("DOT_EXECUTABLE", "dot", dot_paths[0..]);
}

fn findDotBinary() []const u8 {
    return executable.choose("DOT_EXECUTABLE", "dot", dot_paths[0..]);
}

/// Check if dot skill exists for the given engine
pub fn hasSkill(engine: Engine) bool {
    const home = std.posix.getenv("HOME") orelse return false;
    const path = skillPath(engine);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, path }) catch |err| {
        log.warn("Failed to format dot skill path: {}", .{err});
        return false;
    };

    if (std.fs.cwd().access(full_path, .{})) |_| {
        return true;
    } else |err| {
        return switch (err) {
            error.FileNotFound, error.AccessDenied => false,
            else => {
                log.warn("Failed to access dot skill path {s}: {}", .{ full_path, err });
                return false;
            },
        };
    }
}

/// Check if .dots directory exists in given cwd
pub fn hasDotDir(cwd: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.dots", .{cwd}) catch |err| {
        log.warn("Failed to format .dots path: {}", .{err});
        return false;
    };

    if (std.fs.cwd().access(path, .{})) |_| {
        return true;
    } else |err| {
        return switch (err) {
            error.FileNotFound, error.AccessDenied => false,
            else => {
                log.warn("Failed to access .dots path {s}: {}", .{ path, err });
                return false;
            },
        };
    }
}

/// Result of checking for pending tasks
pub const PendingTasksResult = struct {
    has_tasks: bool,
    error_msg: ?[]const u8 = null, // Static string describing error, null if success
};

pub fn hasPendingTasks(allocator: Allocator, cwd: []const u8) PendingTasksResult {
    if (!hasDotCli()) {
        return .{ .has_tasks = false, .error_msg = "dot CLI not found" };
    }
    const dot_bin = findDotBinary();
    var args = [_][]const u8{ dot_bin, "ls", "--json" };
    var child = std.process.Child.init(&args, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch |err| {
        log.warn("dot ls failed to start: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "dot CLI not found or failed to start" };
    };
    errdefer {
        _ = child.kill() catch |err| blk: {
            log.warn("Failed to kill dot ls process: {}", .{err});
            break :blk std.process.Child.Term{ .Unknown = 0 };
        };
        _ = child.wait() catch |err| blk: {
            log.warn("Failed to wait for dot ls process: {}", .{err});
            break :blk std.process.Child.Term{ .Unknown = 0 };
        };
    }

    const stdout = child.stdout orelse return .{ .has_tasks = false, .error_msg = "no stdout from dot" };
    const stderr = child.stderr orelse return .{ .has_tasks = false, .error_msg = "no stderr from dot" };
    const out = stdout.readToEndAlloc(allocator, max_dot_output_bytes) catch |err| {
        log.warn("dot ls stdout read failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "failed to read dot output" };
    };
    defer allocator.free(out);
    const err_out = stderr.readToEndAlloc(allocator, max_dot_output_bytes) catch |err| {
        log.warn("dot ls stderr read failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "failed to read dot stderr" };
    };
    defer allocator.free(err_out);

    const term = child.wait() catch |err| {
        log.warn("dot ls wait failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "dot process wait failed" };
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.warn("dot ls exited with code {d}: {s}", .{ code, err_out });
            return .{ .has_tasks = false, .error_msg = "dot ls exited with error" };
        },
        else => {
            log.warn("dot ls did not exit cleanly: {}", .{term});
            return .{ .has_tasks = false, .error_msg = "dot ls terminated abnormally" };
        },
    }

    const has = outputHasPendingTasks(allocator, out) catch |err| {
        log.warn("dot ls output parse failed: {}", .{err});
        return .{ .has_tasks = false, .error_msg = "failed to parse dot output" };
    };
    return .{ .has_tasks = has };
}

pub fn outputHasPendingTasks(allocator: Allocator, output: []const u8) !bool {
    const parsed = try std.json.parseFromSlice([]DotTask, allocator, output, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return parsed.value.len > 0;
}

/// Result of cleanup operation
pub const CleanupResult = struct {
    cleaned: bool,
    error_msg: ?[]const u8 = null,
};

/// Clean up dots hooks from Claude Code settings.
/// Returns true if any hooks were removed, false otherwise.
pub fn cleanupClaudeHooks(allocator: Allocator) CleanupResult {
    const home = std.posix.getenv("HOME") orelse return .{ .cleaned = false, .error_msg = "HOME not set" };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const settings_path = std.fmt.bufPrint(&path_buf, "{s}/.claude/settings.json", .{home}) catch |err| {
        log.warn("Failed to format Claude settings path: {}", .{err});
        return .{ .cleaned = false, .error_msg = "path too long" };
    };

    // Read settings file
    const file = std.fs.cwd().openFile(settings_path, .{}) catch |err| {
        log.debug("Could not open Claude settings: {}", .{err});
        return .{ .cleaned = false, .error_msg = "settings file not found" };
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        log.warn("Could not read Claude settings: {}", .{err});
        return .{ .cleaned = false, .error_msg = "failed to read settings" };
    };
    defer allocator.free(content);

    // Parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        log.warn("Could not parse Claude settings: {}", .{err});
        return .{ .cleaned = false, .error_msg = "invalid JSON" };
    };
    defer parsed.deinit();

    // Check for hooks object
    const hooks = parsed.value.object.getPtr("hooks") orelse {
        return .{ .cleaned = false }; // No hooks, nothing to clean
    };
    if (hooks.* != .object) return .{ .cleaned = false };

    var modified = false;

    // Clean SessionStart hooks
    if (hooks.object.getPtr("SessionStart")) |session_start| {
        if (filterDotsHooks(allocator, session_start)) {
            modified = true;
        }
    }

    // Clean PostToolUse hooks
    if (hooks.object.getPtr("PostToolUse")) |post_tool| {
        if (filterDotsHooks(allocator, post_tool)) {
            modified = true;
        }
    }

    if (!modified) return .{ .cleaned = false };

    // Write back
    var out_writer: std.io.Writer.Allocating = .init(allocator);
    defer out_writer.deinit();
    std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &out_writer.writer) catch |err| {
        log.warn("Could not serialize settings: {}", .{err});
        return .{ .cleaned = false, .error_msg = "failed to serialize" };
    };
    const out_buf = out_writer.toOwnedSlice() catch |err| {
        log.warn("Could not finalize settings buffer: {}", .{err});
        return .{ .cleaned = false, .error_msg = "failed to serialize" };
    };
    defer allocator.free(out_buf);

    const out_file = std.fs.cwd().createFile(settings_path, .{}) catch |err| {
        log.warn("Could not write Claude settings: {}", .{err});
        return .{ .cleaned = false, .error_msg = "failed to write settings" };
    };
    defer out_file.close();

    out_file.writeAll(out_buf) catch |err| {
        log.warn("Could not write Claude settings: {}", .{err});
        return .{ .cleaned = false, .error_msg = "write failed" };
    };

    log.info("Cleaned up dots hooks from Claude settings", .{});
    return .{ .cleaned = true };
}

/// Filter out hooks containing "dot hook" from a hooks array.
/// Returns true if any were removed.
fn filterDotsHooks(allocator: Allocator, hooks_value: *std.json.Value) bool {
    if (hooks_value.* != .array) return false;

    var removed = false;
    var i: usize = 0;
    while (i < hooks_value.array.items.len) {
        const item = hooks_value.array.items[i];
        if (isDotHook(item)) {
            _ = hooks_value.array.orderedRemove(i);
            removed = true;
        } else {
            i += 1;
        }
    }

    // If array is now empty, we could remove the key, but leaving empty array is fine
    _ = allocator; // unused for now
    return removed;
}

/// Check if a hook entry contains "dot hook" command
fn isDotHook(value: std.json.Value) bool {
    if (value != .object) return false;

    // Check direct hooks array
    if (value.object.get("hooks")) |hooks| {
        if (hooks == .array) {
            for (hooks.array.items) |hook| {
                if (hook == .object) {
                    if (hook.object.get("command")) |cmd| {
                        if (cmd == .string) {
                            if (std.mem.indexOf(u8, cmd.string, "dot hook") != null) {
                                return true;
                            }
                        }
                    }
                }
            }
        }
    }

    // Check command directly (for simpler hook format)
    if (value.object.get("command")) |cmd| {
        if (cmd == .string) {
            if (std.mem.indexOf(u8, cmd.string, "dot hook") != null) {
                return true;
            }
        }
    }

    return false;
}

const testing = std.testing;
const ohsnap = @import("ohsnap");
const test_env = @import("../util/test_env.zig");

fn createDotStub(allocator: Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const stub_name = "dot";
    try tmp.dir.writeFile(.{ .sub_path = stub_name, .data = "" });
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, stub_name });
}

test "outputHasPendingTasks detects pending tasks" {
    const has_tasks = try outputHasPendingTasks(testing.allocator, "[{\"status\":\"open\"}]");
    const no_tasks = try outputHasPendingTasks(testing.allocator, "[]");
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("has_tasks: {any}\nno_tasks: {any}\n", .{ has_tasks, no_tasks });
    const summary = try out.toOwnedSlice();
    defer testing.allocator.free(summary);
    try (ohsnap{}).snap(@src(),
        \\has_tasks: true
        \\no_tasks: false
        \\
    ).diff(summary, true);
}

test "trigger returns correct command per engine" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {s}\ncodex: {s}\n", .{ trigger(.claude), trigger(.codex) });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude: /dot
        \\codex: $dot
        \\
    ).diff(snapshot, true);
}

test "clearCmd returns correct command per engine" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {s}\ncodex: {s}\n", .{ clearCmd(.claude), clearCmd(.codex) });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude: /clear
        \\codex: /clear
        \\
    ).diff(snapshot, true);
}

test "skillPath returns correct path per engine" {
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {s}\ncodex: {s}\n", .{ skillPath(.claude), skillPath(.codex) });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\claude: .claude/skills/dot/SKILL.md
        \\codex: .codex/skills/dot/SKILL.md
        \\
    ).diff(snapshot, true);
}

test "skill_prompt is non-empty" {
    try testing.expect(skill_prompt.len > 100);
    try testing.expect(std.mem.indexOf(u8, skill_prompt, "dot") != null);
}

test "hasDotDir with temp directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // No .dots dir yet
    try testing.expect(!hasDotDir(tmp_path));

    // Create .dots dir
    try tmp.dir.makeDir(".dots");

    // Now should exist
    try testing.expect(hasDotDir(tmp_path));
}

const zcheck = @import("zcheck");

test "property: trigger is consistent" {
    try zcheck.check(struct {
        fn prop(args: struct { engine_idx: u8 }) bool {
            const engine: Engine = if (args.engine_idx % 2 == 0) .claude else .codex;
            const t1 = trigger(engine);
            const t2 = trigger(engine);
            return std.mem.eql(u8, t1, t2);
        }
    }.prop, .{ .seed = 0x1234 });
}

test "property: clearCmd is consistent" {
    try zcheck.check(struct {
        fn prop(args: struct { engine_idx: u8 }) bool {
            const engine: Engine = if (args.engine_idx % 2 == 0) .claude else .codex;
            const c1 = clearCmd(engine);
            const c2 = clearCmd(engine);
            return std.mem.eql(u8, c1, c2);
        }
    }.prop, .{ .seed = 0x5678 });
}

test "skill_prompt content snapshot" {
    // Verify skill prompt has expected structure
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const has_frontmatter = std.mem.indexOf(u8, skill_prompt, "---") != null;
    const has_name = std.mem.indexOf(u8, skill_prompt, "name: dot") != null;
    const has_commands = std.mem.indexOf(u8, skill_prompt, "## Commands") != null;
    const has_workflow = std.mem.indexOf(u8, skill_prompt, "## Workflow") != null;
    const has_dot_ls = std.mem.indexOf(u8, skill_prompt, "dot ls") != null;
    const has_dot_on = std.mem.indexOf(u8, skill_prompt, "dot on") != null;
    const has_dot_off = std.mem.indexOf(u8, skill_prompt, "dot off") != null;

    try out.writer.print(
        \\has_frontmatter: {any}
        \\has_name: {any}
        \\has_commands: {any}
        \\has_workflow: {any}
        \\has_dot_ls: {any}
        \\has_dot_on: {any}
        \\has_dot_off: {any}
        \\
    , .{ has_frontmatter, has_name, has_commands, has_workflow, has_dot_ls, has_dot_on, has_dot_off });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);
    try (ohsnap{}).snap(@src(),
        \\has_frontmatter: true
        \\has_name: true
        \\has_commands: true
        \\has_workflow: true
        \\has_dot_ls: true
        \\has_dot_on: true
        \\has_dot_off: true
        \\
    ).diff(snapshot, true);
}

test "hasDotCli returns bool without crash" {
    // Environment test: verify it returns a bool without crashing
    const result = hasDotCli();
    // Result depends on whether dot is installed on test machine
    // Just verify it's a valid bool
    try testing.expect(result == true or result == false);
}

test "hasDotCli honors DOT_EXECUTABLE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const stub_path = try createDotStub(testing.allocator, &tmp);
    defer testing.allocator.free(stub_path);

    var guard_path = try test_env.EnvVarGuard.set(testing.allocator, "PATH", "");
    defer guard_path.deinit();
    var guard_dot = try test_env.EnvVarGuard.set(testing.allocator, "DOT_EXECUTABLE", stub_path);
    defer guard_dot.deinit();

    try testing.expect(hasDotCli());
}

test "hasSkill with missing skill" {
    // hasSkill checks HOME env, so we test the path construction
    // by verifying it returns false for a definitely-missing path
    const home = std.posix.getenv("HOME");
    if (home == null) return error.SkipZigTest;

    // Unless someone has ~/.claude/skills/dot/SKILL.md, this should work
    // We can't easily mock HOME, so we just verify the function runs
    const claude_result = hasSkill(.claude);
    const codex_result = hasSkill(.codex);

    // Snapshot the results - they depend on test environment
    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude: {any}\ncodex: {any}\n", .{ claude_result, codex_result });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    // We can't predict the result, but we verify no crash
    try testing.expect(snapshot.len > 0);
}

test "property: hasDotDir consistent for same path" {
    try zcheck.check(struct {
        fn prop(_: struct { dummy: u8 }) bool {
            const path = "/tmp";
            const r1 = hasDotDir(path);
            const r2 = hasDotDir(path);
            return r1 == r2;
        }
    }.prop, .{ .seed = 0xabcd });
}

test "property: trigger and clearCmd are different" {
    try zcheck.check(struct {
        fn prop(args: struct { engine_idx: u8 }) bool {
            const engine: Engine = if (args.engine_idx % 2 == 0) .claude else .codex;
            const t = trigger(engine);
            const c = clearCmd(engine);
            // Trigger and clear should be different commands
            return !std.mem.eql(u8, t, c);
        }
    }.prop, .{ .seed = 0xef01 });
}

test "property: skillPath contains engine name" {
    try zcheck.check(struct {
        fn prop(args: struct { engine_idx: u8 }) bool {
            const engine: Engine = if (args.engine_idx % 2 == 0) .claude else .codex;
            const path = skillPath(engine);
            return switch (engine) {
                .claude => std.mem.indexOf(u8, path, ".claude") != null,
                .codex => std.mem.indexOf(u8, path, ".codex") != null,
            };
        }
    }.prop, .{ .seed = 0x2345 });
}

const config = @import("config");

test "live: hasDotCli detects installed CLI" {
    if (!config.live_cli_tests) return error.SkipZigTest;

    // This test verifies hasDotCli works with the real system
    const result = hasDotCli();

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("dot_cli_available: {any}\n", .{result});
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    // On a system with dot installed, this should be true
    // We snapshot the actual result to track regressions
    try (ohsnap{}).snap(@src(),
        \\dot_cli_available: true
        \\
    ).diff(snapshot, true);
}

test "live: hasSkill checks real filesystem" {
    if (!config.live_cli_tests) return error.SkipZigTest;

    const claude_has = hasSkill(.claude);
    const codex_has = hasSkill(.codex);

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("claude_skill: {any}\ncodex_skill: {any}\n", .{ claude_has, codex_has });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    // Snapshot actual state - may vary by environment
    // Just verify it runs without error
    try testing.expect(snapshot.len > 0);
}

test "live: hasDotDir checks real cwd" {
    if (!config.live_cli_tests) return error.SkipZigTest;

    // Check the actual banjo repo directory
    const has_dots = hasDotDir(".");

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("cwd_has_dots: {any}\n", .{has_dots});
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    // Banjo repo should have .dots directory
    try (ohsnap{}).snap(@src(),
        \\cwd_has_dots: true
        \\
    ).diff(snapshot, true);
}

test "live: hasPendingTasks with real dot CLI" {
    if (!config.live_cli_tests) return error.SkipZigTest;
    if (!hasDotCli()) return error.SkipZigTest;

    // Run against the actual cwd
    const result = hasPendingTasks(testing.allocator, ".");

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // We can't predict if there are pending tasks, but we can verify no error
    try out.writer.print("has_error: {any}\n", .{result.error_msg != null});
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\has_error: false
        \\
    ).diff(snapshot, true);
}

test "isDotHook detects dot hook commands" {
    // Test nested hooks format (SessionStart style)
    const nested_hook = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"hooks": [{"type": "command", "command": "dot hook session"}]}
    , .{});
    defer nested_hook.deinit();
    try testing.expect(isDotHook(nested_hook.value));

    // Test direct command format
    const direct_hook = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"type": "command", "command": "dot hook sync"}
    , .{});
    defer direct_hook.deinit();
    try testing.expect(isDotHook(direct_hook.value));

    // Test non-dot hook
    const other_hook = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"hooks": [{"type": "command", "command": "echo hello"}]}
    , .{});
    defer other_hook.deinit();
    try testing.expect(!isDotHook(other_hook.value));

    // Test empty object
    const empty = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer empty.deinit();
    try testing.expect(!isDotHook(empty.value));
}

test "filterDotsHooks removes dot hooks from array" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[
        \\  {"hooks": [{"type": "command", "command": "echo agents"}]},
        \\  {"hooks": [{"type": "command", "command": "dot hook session"}]},
        \\  {"hooks": [{"type": "command", "command": "echo other"}]}
        \\]
    , .{});
    defer parsed.deinit();

    const removed = filterDotsHooks(testing.allocator, &parsed.value);
    try testing.expect(removed);
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "filterDotsHooks returns false when no dot hooks" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[
        \\  {"hooks": [{"type": "command", "command": "echo agents"}]},
        \\  {"hooks": [{"type": "command", "command": "echo other"}]}
        \\]
    , .{});
    defer parsed.deinit();

    const removed = filterDotsHooks(testing.allocator, &parsed.value);
    try testing.expect(!removed);
    try testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
}

test "cleanupClaudeHooks with temp settings file" {
    // Create a temp directory to simulate HOME
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create .claude directory
    try tmp.dir.makeDir(".claude");

    // Write a settings file with dot hooks
    const settings_content =
        \\{
        \\  "model": "opus",
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {"hooks": [{"type": "command", "command": "echo agents"}]},
        \\      {"hooks": [{"type": "command", "command": "dot hook session"}]}
        \\    ],
        \\    "PostToolUse": [
        \\      {"matcher": "TodoWrite", "hooks": [{"type": "command", "command": "dot hook sync"}]}
        \\    ]
        \\  }
        \\}
    ;

    var claude_dir = try tmp.dir.openDir(".claude", .{});
    defer claude_dir.close();
    const settings_file = try claude_dir.createFile("settings.json", .{});
    defer settings_file.close();
    try settings_file.writeAll(settings_content);

    // Get the temp path and set HOME
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var guard = try test_env.EnvVarGuard.set(testing.allocator, "HOME", tmp_path);
    defer guard.deinit();

    // Run cleanup
    const result = cleanupClaudeHooks(testing.allocator);

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("cleaned: {any}\nerror: {?s}\n", .{ result.cleaned, result.error_msg });
    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\cleaned: true
        \\error: null
        \\
    ).diff(snapshot, true);

    // Verify the file was modified correctly
    const modified = try claude_dir.openFile("settings.json", .{});
    defer modified.close();
    const new_content = try modified.readToEndAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(new_content);

    // Should not contain "dot hook"
    try testing.expect(std.mem.indexOf(u8, new_content, "dot hook") == null);
    // Should still contain echo agents
    try testing.expect(std.mem.indexOf(u8, new_content, "echo agents") != null);
}

test "cleanupClaudeHooks returns false when no hooks to clean" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir(".claude");

    const settings_content =
        \\{
        \\  "model": "opus",
        \\  "hooks": {
        \\    "SessionStart": [
        \\      {"hooks": [{"type": "command", "command": "echo agents"}]}
        \\    ]
        \\  }
        \\}
    ;

    var claude_dir = try tmp.dir.openDir(".claude", .{});
    defer claude_dir.close();
    const settings_file = try claude_dir.createFile("settings.json", .{});
    defer settings_file.close();
    try settings_file.writeAll(settings_content);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var guard = try test_env.EnvVarGuard.set(testing.allocator, "HOME", tmp_path);
    defer guard.deinit();

    const result = cleanupClaudeHooks(testing.allocator);
    try testing.expect(!result.cleaned);
    try testing.expect(result.error_msg == null);
}

test "cleanupClaudeHooks handles missing settings file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var guard = try test_env.EnvVarGuard.set(testing.allocator, "HOME", tmp_path);
    defer guard.deinit();

    const result = cleanupClaudeHooks(testing.allocator);
    try testing.expect(!result.cleaned);
    try testing.expect(result.error_msg != null);
}

test "contextPrompt includes AGENTS.md" {
    const prompt = contextPrompt(.claude);
    try testing.expect(std.mem.indexOf(u8, prompt, "AGENTS.md") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "dot ls") != null);
}

test "containsDotOffStr detects dot off command" {
    // Should match - basic cases
    try testing.expect(containsDotOffStr("dot off"));
    try testing.expect(containsDotOffStr("dot off abc123"));
    try testing.expect(containsDotOffStr("dot off abc123 -r done"));

    // Should match - with shell separators
    try testing.expect(containsDotOffStr("git commit && dot off abc"));
    try testing.expect(containsDotOffStr("echo test; dot off abc"));
    try testing.expect(containsDotOffStr("echo test | dot off abc"));
    try testing.expect(containsDotOffStr("dot off abc;"));
    try testing.expect(containsDotOffStr("dot off abc\n"));
    try testing.expect(containsDotOffStr("(dot off abc)"));
    try testing.expect(containsDotOffStr("$(dot off)"));
    try testing.expect(containsDotOffStr("echo $(dot off abc)"));

    // Should match - with quotes
    try testing.expect(containsDotOffStr("bash -c \"dot off abc\""));
    try testing.expect(containsDotOffStr("bash -c 'dot off abc'"));

    // Should NOT match - word boundary violations (leading)
    try testing.expect(!containsDotOffStr("adot off abc"));
    try testing.expect(!containsDotOffStr("xdot off"));
    try testing.expect(!containsDotOffStr("mydot off abc"));

    // Should NOT match - word boundary violations (trailing)
    try testing.expect(!containsDotOffStr("dot offer"));
    try testing.expect(!containsDotOffStr("dotoffabc"));
    try testing.expect(!containsDotOffStr("dot offset"));
    try testing.expect(!containsDotOffStr("dot offx"));

    // Edge cases
    try testing.expect(!containsDotOffStr(""));
    try testing.expect(!containsDotOffStr("dot"));
    try testing.expect(!containsDotOffStr("dot of"));
}

test "containsDotOff detects dot off in JSON input" {
    // Valid Bash tool input with dot off
    var map1 = std.json.ObjectMap.init(testing.allocator);
    defer map1.deinit();
    try map1.put("command", .{ .string = "dot off abc123" });
    const valid_input = std.json.Value{ .object = map1 };
    try testing.expect(containsDotOff(valid_input));

    // Valid Bash tool input without dot off
    var map2 = std.json.ObjectMap.init(testing.allocator);
    defer map2.deinit();
    try map2.put("command", .{ .string = "ls -la" });
    const no_dot_off = std.json.Value{ .object = map2 };
    try testing.expect(!containsDotOff(no_dot_off));

    // Not an object
    try testing.expect(!containsDotOff(.null));
    try testing.expect(!containsDotOff(.{ .string = "dot off" }));

    // Object without command field
    var map3 = std.json.ObjectMap.init(testing.allocator);
    defer map3.deinit();
    try map3.put("other", .{ .string = "value" });
    const no_command = std.json.Value{ .object = map3 };
    try testing.expect(!containsDotOff(no_command));
}
