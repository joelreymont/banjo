const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Agent = @import("acp/agent.zig").Agent;
const LspServer = @import("lsp/server.zig").Server;
const DaemonHandler = @import("ws/handler.zig").Handler;
const config = @import("config");

const log = std.log.scoped(.banjo);

// Override std.log to write to file instead of stderr
pub const std_options: std.Options = .{
    .logFn = fileLogFn,
};

var log_file: ?std.fs.File = null;

fn fileLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const file = log_file orelse std.fs.File.stderr();
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ fmt ++ "\n", args) catch |err| {
        std.debug.panic("banjo log format failed: {}", .{err});
    };
    file.deprecatedWriter().writeAll(msg) catch |err| {
        std.debug.panic("banjo log write failed: {}", .{err});
    };
}

/// Run mode
const Mode = enum {
    agent, // ACP agent mode (default)
    lsp, // LSP server mode
    daemon, // WebSocket daemon mode
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
    mode_daemon,
    verbose,
    session_id,
    permission_mode,
    help,
};

const Subcommand = enum {
    hook,
};

const HookSubcommand = enum {
    permission,
};

const arg_map = std.StaticStringMap(ArgAction).initComptime(.{
    .{ "--agent", .mode_agent },
    .{ "--lsp", .mode_lsp },
    .{ "--daemon", .mode_daemon },
    .{ "--nvim", .mode_daemon }, // Keep for backward compat
    .{ "--verbose", .verbose },
    .{ "-v", .verbose },
    .{ "--session-id", .session_id },
    .{ "--permission-mode", .permission_mode },
    .{ "-h", .help },
    .{ "--help", .help },
});

const subcommand_map = std.StaticStringMap(Subcommand).initComptime(.{
    .{ "hook", .hook },
});

const hook_map = std.StaticStringMap(HookSubcommand).initComptime(.{
    .{ "permission", .permission },
});

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    var opts = CliOptions{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip program name

    // Check for subcommand first
    if (args.next()) |first_arg| {
        if (subcommand_map.get(first_arg)) |subcommand| {
            switch (subcommand) {
                .hook => {
                    if (args.next()) |hook_type| {
                        if (hook_map.get(hook_type)) |hook_cmd| {
                            switch (hook_cmd) {
                                .permission => {
                                    opts.mode = .hook_permission;
                                    return opts;
                                },
                            }
                        }
                    }
                    printHookHelp();
                    std.process.exit(1);
                },
            }
        }

        // Not a subcommand, check if it's a flag
        if (arg_map.get(first_arg)) |action| {
            switch (action) {
                .mode_agent => opts.mode = .agent,
                .mode_lsp => opts.mode = .lsp,
                .mode_daemon => opts.mode = .daemon,
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
            .mode_daemon => opts.mode = .daemon,
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
    std.fs.File.stderr().writeAll("Usage: banjo hook <permission>\n") catch |err| {
        log.warn("Failed to write hook help: {}", .{err});
    };
}

fn printHelp() void {
    std.fs.File.stderr().writeAll(
        \\Banjo - A Second Brain for your code
        \\
        \\Usage: banjo [MODE] [OPTIONS]
        \\       banjo hook <subcommand>
        \\
        \\Modes:
        \\  --agent                     ACP agent mode (default)
        \\  --lsp                       LSP server mode for note stickies
        \\  --daemon                    WebSocket daemon for editor clients
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
fn hookDebugLog(comptime fmt: []const u8, args: anytype) !void {
    const file = try std.fs.cwd().createFile("/tmp/banjo-hook-debug.log", .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    var buf: [1024]u8 = undefined;
    const now = std.time.timestamp();
    const prefix_len = try std.fmt.bufPrint(&buf, "[{d}] ", .{now});
    try file.writeAll(prefix_len);
    const msg_len = try std.fmt.bufPrint(&buf, fmt ++ "\n", args);
    try file.writeAll(msg_len);
}

fn hookDebugLogBestEffort(comptime fmt: []const u8, args: anytype) void {
    hookDebugLog(fmt, args) catch |err| {
        log.warn("hook debug log failed: {}", .{err});
    };
}

/// Run the permission hook - reads from stdin, connects to Banjo socket, returns decision
fn runPermissionHook(allocator: std.mem.Allocator) !void {
    const max_input = 64 * 1024;
    const stdin = std.fs.File.stdin();

    // Always read stdin first to avoid broken pipe errors
    const input = stdin.readToEndAlloc(allocator, max_input) catch |err| {
        hookDebugLogBestEffort("Failed to read stdin: {}", .{err});
        log.warn("Failed to read stdin: {}", .{err});
        return err;
    };
    defer allocator.free(input);

    // Check for Banjo socket - if not set, exit silently (defer to default permission handling)
    const socket_path = std.posix.getenv("BANJO_PERMISSION_SOCKET") orelse return;

    hookDebugLogBestEffort("Hook invoked, socket={s}", .{socket_path});

    const stdout = std.fs.File.stdout();

    hookDebugLogBestEffort("Read {d} bytes from stdin", .{input.len});

    if (input.len == 0) return;

    // Parse hook input
    var parsed = std.json.parseFromSlice(HookInput, allocator, input, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        hookDebugLogBestEffort("Failed to parse hook input: {}", .{err});
        log.warn("Failed to parse hook input: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    const hook_input = parsed.value;
    hookDebugLogBestEffort("Parsed hook: tool={s} session={s}", .{ hook_input.tool_name, hook_input.session_id });

    // Connect to Banjo socket
    const sock = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
        hookDebugLogBestEffort("Failed to create socket: {}", .{err});
        log.warn("Failed to create socket: {}", .{err});
        return err;
    };
    defer std.posix.close(sock);

    // Set timeout (non-critical, socket works without it)
    const timeout = std.posix.timeval{ .sec = 60, .usec = 0 };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        hookDebugLogBestEffort("setsockopt RCVTIMEO failed: {}", .{err});
    };
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
        hookDebugLogBestEffort("setsockopt SNDTIMEO failed: {}", .{err});
    };

    // Connect
    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    const path_len = @min(socket_path.len, addr.path.len - 1);
    @memcpy(addr.path[0..path_len], socket_path[0..path_len]);

    hookDebugLogBestEffort("Connecting to socket...", .{});
    std.posix.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
        hookDebugLogBestEffort("Failed to connect to socket: {}", .{err});
        log.warn("Failed to connect to socket: {}", .{err});
        return err;
    };
    hookDebugLogBestEffort("Connected to socket", .{});

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
    }) catch |err| {
        hookDebugLogBestEffort("Failed to serialize request: {}", .{err});
        return err;
    };
    out.writer.writeAll("\n") catch |err| {
        hookDebugLogBestEffort("Failed to write newline: {}", .{err});
        return err;
    };
    const request = out.toOwnedSlice() catch |err| {
        hookDebugLogBestEffort("Failed to allocate request: {}", .{err});
        return err;
    };
    defer allocator.free(request);

    _ = std.posix.write(sock, request) catch |err| {
        hookDebugLogBestEffort("Failed to write to socket: {}", .{err});
        log.warn("Failed to write to socket: {}", .{err});
        return err;
    };

    // Read response
    var response_buf: [1024]u8 = undefined;
    const n = std.posix.read(sock, &response_buf) catch |err| {
        hookDebugLogBestEffort("Failed to read from socket: {}", .{err});
        log.warn("Failed to read from socket: {}", .{err});
        return err;
    };
    if (n == 0) {
        hookDebugLogBestEffort("Empty response from socket", .{});
        return error.UnexpectedEof;
    }

    const response = std.mem.trimRight(u8, response_buf[0..n], "\n\r");

    // Parse response
    var resp_parsed = std.json.parseFromSlice(HookSocketResponse, allocator, response, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        hookDebugLogBestEffort("Failed to parse response: {}", .{err});
        return err;
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
        hookDebugLogBestEffort("Outputting decision: {s}", .{resp.decision});
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
                    }) catch |err| {
                        hookDebugLogBestEffort("Failed to write hook output: {}", .{err});
                        return err;
                    };
                    const hook_json = hook_out.toOwnedSlice() catch |err| {
                        hookDebugLogBestEffort("Failed to allocate hook output: {}", .{err});
                        return err;
                    };
                    defer allocator.free(hook_json);
                    stdout.writeAll(hook_json) catch |err| {
                        hookDebugLogBestEffort("Failed to write to stdout: {}", .{err});
                        return err;
                    };
                } else {
                    stdout.writeAll(
                        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
                    ) catch |err| {
                        hookDebugLogBestEffort("Failed to write allow to stdout: {}", .{err});
                        return err;
                    };
                }
            },
            .deny => {
                // Include reason if provided
                if (resp.reason) |reason| {
                    var buf: [512]u8 = undefined;
                    const output = std.fmt.bufPrint(&buf, "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"{s}\"}}}}", .{reason}) catch |err| {
                        hookDebugLogBestEffort("Failed to format deny output: {}", .{err});
                        return err;
                    };
                    stdout.writeAll(output) catch |err| {
                        hookDebugLogBestEffort("Failed to write deny to stdout: {}", .{err});
                        return err;
                    };
                } else {
                    stdout.writeAll(
                        \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Permission denied by Banjo"}}
                    ) catch |err| {
                        hookDebugLogBestEffort("Failed to write default deny to stdout: {}", .{err});
                        return err;
                    };
                }
            },
        }
    } else {
        hookDebugLogBestEffort("Unknown decision: {s}, deferring to default", .{resp.decision});
    }
    // For "ask" or unknown, output nothing - defer to default permission flow
}

pub fn main() !void {
    // Initialize file-based logging (writes to /tmp/banjo.log by default)
    const log_path = std.posix.getenv("BANJO_LOG_FILE") orelse "/tmp/banjo.log";
    log_file = blk: {
        const file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch |err| {
            std.debug.print("Failed to open log file {s}: {}\n", .{ log_path, err });
            break :blk null;
        };
        file.seekFromEnd(0) catch |err| {
            std.debug.print("Failed to seek log file {s}: {}\n", .{ log_path, err });
            file.close();
            break :blk null;
        };
        break :blk file;
    };
    defer if (log_file) |f| f.close();

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
        .daemon => {
            log.info("Banjo daemon v{s} ({s}) starting", .{ config.version, config.git_hash });
            var handler = try DaemonHandler.init(allocator, stdin, stdout);
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
    _ = @import("util/log.zig");

    // Notes (comment-based)
    _ = @import("notes/comments.zig");
    _ = @import("notes/commands.zig");

    // LSP server
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/diagnostics.zig");
    _ = @import("lsp/server.zig");

    // WebSocket daemon
    _ = @import("ws/protocol.zig");
    _ = @import("ws/handler.zig");
}
