const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Agent = @import("acp/agent.zig").Agent;
const LspServer = @import("lsp/server.zig").Server;
const NvimHandler = @import("nvim/handler.zig").Handler;
const config = @import("config");

const log = std.log.scoped(.banjo);

/// Run mode
const Mode = enum {
    agent, // ACP agent mode (default)
    lsp, // LSP server mode
    nvim, // Neovim handler mode
    hook_permission, // Permission hook for Claude Code
};

/// CLI options matching Claude Code interface
const CliOptions = struct {
    mode: Mode = .agent,
    verbose: bool = false,
    session_id: ?[]const u8 = null,
    permission_mode: []const u8 = "default",
    permission_mode_owned: bool = false,

    pub fn deinit(self: *const CliOptions, allocator: std.mem.Allocator) void {
        if (self.session_id) |sid| allocator.free(sid);
        if (self.permission_mode_owned) allocator.free(self.permission_mode);
    }
};

const ArgAction = enum {
    mode_agent,
    mode_lsp,
    mode_nvim,
    verbose,
    session_id,
    permission_mode,
    help,
};

const arg_map = std.StaticStringMap(ArgAction).initComptime(.{
    .{ "--agent", .mode_agent },
    .{ "--lsp", .mode_lsp },
    .{ "--nvim", .mode_nvim },
    .{ "--verbose", .verbose },
    .{ "-v", .verbose },
    .{ "--session-id", .session_id },
    .{ "--permission-mode", .permission_mode },
    .{ "-h", .help },
    .{ "--help", .help },
});

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    var opts = CliOptions{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip program name

    // Check for subcommand first
    if (args.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "hook")) {
            // Hook subcommand
            if (args.next()) |hook_type| {
                if (std.mem.eql(u8, hook_type, "permission")) {
                    opts.mode = .hook_permission;
                    return opts;
                }
            }
            printHookHelp();
            std.process.exit(1);
        }

        // Not a subcommand, check if it's a flag
        if (arg_map.get(first_arg)) |action| {
            switch (action) {
                .mode_agent => opts.mode = .agent,
                .mode_lsp => opts.mode = .lsp,
                .mode_nvim => opts.mode = .nvim,
                .verbose => opts.verbose = true,
                .session_id => {
                    if (args.next()) |sid| {
                        opts.session_id = try allocator.dupe(u8, sid);
                    }
                },
                .permission_mode => {
                    if (args.next()) |mode| {
                        opts.permission_mode = try allocator.dupe(u8, mode);
                        opts.permission_mode_owned = true;
                    }
                },
                .help => {
                    printHelp();
                    std.process.exit(0);
                },
            }
        }
    }

    while (args.next()) |arg| {
        const action = arg_map.get(arg) orelse continue;
        switch (action) {
            .mode_agent => opts.mode = .agent,
            .mode_lsp => opts.mode = .lsp,
            .mode_nvim => opts.mode = .nvim,
            .verbose => opts.verbose = true,
            .session_id => {
                if (opts.session_id) |sid| allocator.free(sid);
                if (args.next()) |sid| {
                    opts.session_id = try allocator.dupe(u8, sid);
                } else {
                    opts.session_id = null;
                }
            },
            .permission_mode => {
                if (opts.permission_mode_owned) {
                    allocator.free(opts.permission_mode);
                    opts.permission_mode_owned = false;
                }
                if (args.next()) |mode| {
                    opts.permission_mode = try allocator.dupe(u8, mode);
                    opts.permission_mode_owned = true;
                } else {
                    opts.permission_mode = "default";
                }
            },
            .help => {
                printHelp();
                std.process.exit(0);
            },
        }
    }

    return opts;
}

fn printHookHelp() void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.writeAll("Usage: banjo hook <permission>\n") catch |err| {
        log.warn("Failed to write hook help: {}", .{err});
    };
}

fn printHelp() void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.writeAll(
        \\Banjo - A Second Brain for your code
        \\
        \\Usage: banjo [MODE] [OPTIONS]
        \\       banjo hook <subcommand>
        \\
        \\Modes:
        \\  --agent                     ACP agent mode (default)
        \\  --lsp                       LSP server mode for note stickies
        \\  --nvim                      Neovim handler mode
        \\
        \\Hook subcommands:
        \\  hook permission             Claude Code PermissionRequest hook
        \\
        \\Options:
        \\  --verbose                   Enable verbose logging
        \\  --session-id <id>           Session ID for resuming
        \\  --permission-mode <mode>    Permission mode: default, plan, etc.
        \\  -h, --help                  Show this help
        \\
    ) catch |err| {
        log.warn("Failed to write help: {}", .{err});
    };
}

// Hook input/output types for Claude Code PreToolUse hook
const HookInput = struct {
    tool_name: []const u8 = "",
    tool_input: std.json.Value = .null,
    tool_use_id: []const u8 = "",
    session_id: []const u8 = "",
    hook_event_name: []const u8 = "",
    permission_mode: []const u8 = "",
};

const HookSocketRequest = struct {
    tool_name: []const u8,
    tool_input: std.json.Value,
    tool_use_id: []const u8,
    session_id: []const u8,
};

const HookSocketResponse = struct {
    decision: []const u8 = "ask",
    reason: ?[]const u8 = null,
    answers: ?std.json.Value = null,
};

/// Debug log to file (hooks stderr may not be visible)
fn hookDebugLog(comptime fmt: []const u8, args: anytype) void {
    const file = std.fs.cwd().createFile("/tmp/banjo-hook-debug.log", .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    var buf: [1024]u8 = undefined;
    const now = std.time.timestamp();
    const prefix_len = std.fmt.bufPrint(&buf, "[{d}] ", .{now}) catch return;
    file.writeAll(prefix_len) catch return;
    const msg_len = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    file.writeAll(msg_len) catch return;
}

/// Run the permission hook - reads from stdin, connects to Banjo socket, returns decision
fn runPermissionHook(allocator: std.mem.Allocator) !void {
    const max_input = 64 * 1024;
    const stdin = std.fs.File.stdin();

    // Always read stdin first to avoid broken pipe errors
    const input = stdin.readToEndAlloc(allocator, max_input) catch |err| {
        hookDebugLog("Failed to read stdin: {}", .{err});
        log.warn("Failed to read stdin: {}", .{err});
        return;
    };
    defer allocator.free(input);

    // Check for Banjo socket - if not set, exit silently (defer to default permission handling)
    const socket_path = std.posix.getenv("BANJO_PERMISSION_SOCKET") orelse return;

    hookDebugLog("Hook invoked, socket={s}", .{socket_path});

    const stdout = std.fs.File.stdout().deprecatedWriter();

    hookDebugLog("Read {d} bytes from stdin", .{input.len});

    if (input.len == 0) return;

    // Parse hook input
    var parsed = std.json.parseFromSlice(HookInput, allocator, input, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        hookDebugLog("Failed to parse hook input: {}", .{err});
        log.warn("Failed to parse hook input: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const hook_input = parsed.value;
    hookDebugLog("Parsed hook: tool={s} session={s}", .{ hook_input.tool_name, hook_input.session_id });

    // Connect to Banjo socket
    const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
        hookDebugLog("Failed to create socket: {}", .{err});
        log.warn("Failed to create socket: {}", .{err});
        return;
    };
    defer std.posix.close(sock);

    // Set timeout (non-critical, socket works without it)
    const timeout = std.posix.timeval{ .sec = 60, .usec = 0 };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        hookDebugLog("setsockopt RCVTIMEO failed: {}", .{err});
    };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        hookDebugLog("setsockopt SNDTIMEO failed: {}", .{err});
    };

    // Connect
    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    const path_len = @min(socket_path.len, addr.path.len - 1);
    @memcpy(addr.path[0..path_len], socket_path[0..path_len]);

    hookDebugLog("Connecting to socket...", .{});
    std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
        hookDebugLog("Failed to connect to socket: {}", .{err});
        log.warn("Failed to connect to socket: {}", .{err});
        return;
    };
    hookDebugLog("Connected to socket", .{});

    // Send request as JSON
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    jw.write(HookSocketRequest{
        .tool_name = hook_input.tool_name,
        .tool_input = hook_input.tool_input,
        .tool_use_id = hook_input.tool_use_id,
        .session_id = hook_input.session_id,
    }) catch return;
    out.writer.writeAll("\n") catch return;
    const request = out.toOwnedSlice() catch return;
    defer allocator.free(request);

    _ = std.posix.write(sock, request) catch |err| {
        log.warn("Failed to write to socket: {}", .{err});
        return;
    };

    // Read response
    var response_buf: [1024]u8 = undefined;
    const n = std.posix.read(sock, &response_buf) catch |err| {
        log.warn("Failed to read from socket: {}", .{err});
        return;
    };
    if (n == 0) return;

    const response = std.mem.trimRight(u8, response_buf[0..n], "\n\r");

    // Parse response
    var resp_parsed = std.json.parseFromSlice(HookSocketResponse, allocator, response, .{
        .ignore_unknown_fields = true,
    }) catch {
        return;
    };
    defer resp_parsed.deinit();

    const resp = resp_parsed.value;

    // Output Claude Code hook format for PreToolUse
    const Decision = enum { allow, deny };
    const decision_map = std.StaticStringMap(Decision).initComptime(.{
        .{ "allow", .allow },
        .{ "deny", .deny },
    });

    if (decision_map.get(resp.decision)) |decision| {
        hookDebugLog("Outputting decision: {s}", .{resp.decision});
        switch (decision) {
            .allow => {
                // Check if we have answers to include (for AskUserQuestion)
                if (resp.answers) |answers| {
                    // Build JSON with updatedInput containing answers
                    var hook_out: std.io.Writer.Allocating = .init(allocator);
                    defer hook_out.deinit();
                    var hook_jw: std.json.Stringify = .{
                        .writer = &hook_out.writer,
                        .options = .{ .emit_null_optional_fields = false },
                    };
                    const HookOutput = struct {
                        hookSpecificOutput: struct {
                            hookEventName: []const u8 = "PreToolUse",
                            permissionDecision: []const u8 = "allow",
                            updatedInput: struct { answers: std.json.Value },
                        },
                    };
                    hook_jw.write(HookOutput{
                        .hookSpecificOutput = .{ .updatedInput = .{ .answers = answers } },
                    }) catch return;
                    const hook_json = hook_out.toOwnedSlice() catch return;
                    defer allocator.free(hook_json);
                    stdout.writeAll(hook_json) catch return;
                } else {
                    stdout.writeAll(
                        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
                    ) catch return;
                }
            },
            .deny => {
                // Include reason if provided
                if (resp.reason) |reason| {
                    var buf: [512]u8 = undefined;
                    const output = std.fmt.bufPrint(&buf, "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"{s}\"}}}}", .{reason}) catch return;
                    stdout.writeAll(output) catch return;
                } else {
                    stdout.writeAll(
                        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission denied by Banjo"}}
                    ) catch return;
                }
            },
        }
    } else {
        hookDebugLog("Unknown decision: {s}, deferring to default", .{resp.decision});
    }
    // For "ask" or unknown, output nothing - defer to default permission flow
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = try parseArgs(allocator);
    defer opts.deinit(allocator);

    const stdin = std.fs.File.stdin().deprecatedReader().any();
    const stdout = std.fs.File.stdout().deprecatedWriter().any();

    switch (opts.mode) {
        .lsp => {
            log.info("Banjo Duet LSP v{s} ({s}) starting", .{ config.version, config.git_hash });
            var server = LspServer.init(allocator, stdin, stdout);
            defer server.deinit();
            try server.run();
        },
        .agent => {
            log.info("Banjo Duet v{s} ({s}) starting", .{ config.version, config.git_hash });
            if (opts.verbose) {
                if (opts.session_id) |sid| {
                    log.info("Session ID: {s}", .{sid});
                }
            }

            var reader = jsonrpc.Reader.initWithFd(allocator, stdin, std.posix.STDIN_FILENO);
            defer reader.deinit();

            var acp_agent = Agent.init(allocator, stdout, &reader);
            defer acp_agent.deinit();

            // Main event loop
            while (true) {
                var parsed = reader.nextMessage() catch |err| {
                    log.err("Failed to parse message: {}", .{err});
                    continue;
                } orelse {
                    if (opts.verbose) {
                        log.info("EOF received, shutting down", .{});
                    }
                    break;
                };
                defer parsed.deinit();

                acp_agent.handleMessage(parsed.message) catch |err| {
                    log.err("Failed to handle message: {}", .{err});
                };
            }
        },
        .nvim => {
            log.info("Banjo Neovim v{s} ({s}) starting", .{ config.version, config.git_hash });
            var handler = NvimHandler.init(allocator, stdin, stdout);
            defer handler.deinit();
            try handler.run();
        },
        .hook_permission => {
            try runPermissionHook(allocator);
        },
    }
}

// Re-export modules for testing
pub const protocol = @import("acp/protocol.zig");
pub const agent = @import("acp/agent.zig");

// Test imports
test {
    _ = jsonrpc;
    _ = @import("acp/agent.zig");
    _ = @import("acp/protocol.zig");
    _ = @import("core/claude_bridge.zig");
    _ = @import("core/codex_bridge.zig");
    _ = @import("core/callbacks.zig");
    _ = @import("core/dots.zig");
    _ = @import("core/engine.zig");
    _ = @import("core/settings.zig");
    _ = @import("core/types.zig");
    _ = @import("tools/proxy.zig");
    _ = @import("util/quickcheck.zig");

    // Notes (comment-based)
    _ = @import("notes/comments.zig");
    _ = @import("notes/commands.zig");

    // LSP server
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/diagnostics.zig");
    _ = @import("lsp/server.zig");

    // Neovim handler
    _ = @import("nvim/protocol.zig");
    _ = @import("nvim/handler.zig");
}
