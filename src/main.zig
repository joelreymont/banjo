const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Agent = @import("acp/agent.zig").Agent;
const LspServer = @import("lsp/server.zig").Server;
const config = @import("config");

const log = std.log.scoped(.banjo);

/// Run mode
const Mode = enum {
    agent, // ACP agent mode (default)
    lsp, // LSP server mode
};

/// CLI options matching Claude Code interface
const CliOptions = struct {
    mode: Mode = .agent,
    verbose: bool = false,
    session_id: ?[]const u8 = null,
    permission_mode: []const u8 = "default",
};

const ArgAction = enum {
    mode_agent,
    mode_lsp,
    verbose,
    session_id,
    permission_mode,
    help,
};

const arg_map = std.StaticStringMap(ArgAction).initComptime(.{
    .{ "--agent", .mode_agent },
    .{ "--lsp", .mode_lsp },
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

    while (args.next()) |arg| {
        const action = arg_map.get(arg) orelse continue;
        switch (action) {
            .mode_agent => opts.mode = .agent,
            .mode_lsp => opts.mode = .lsp,
            .verbose => opts.verbose = true,
            .session_id => opts.session_id = args.next(),
            .permission_mode => opts.permission_mode = args.next() orelse "default",
            .help => {
                printHelp();
                std.process.exit(0);
            },
        }
    }

    return opts;
}

fn printHelp() void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;
    w.writeAll(
        \\Banjo - A Second Brain for your code
        \\
        \\Usage: banjo [MODE] [OPTIONS]
        \\
        \\Modes:
        \\  --agent                     ACP agent mode (default)
        \\  --lsp                       LSP server mode for note stickies
        \\
        \\Options:
        \\  --verbose                   Enable verbose logging
        \\  --session-id <id>           Session ID for resuming
        \\  --permission-mode <mode>    Permission mode: default, plan, etc.
        \\  -h, --help                  Show this help
        \\
    ) catch {};
    w.flush() catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const opts = try parseArgs(allocator);

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
    _ = @import("cli/bridge.zig");
    _ = @import("cli/codex_bridge.zig");
    _ = @import("settings/loader.zig");
    _ = @import("tools/proxy.zig");
    _ = @import("util/quickcheck.zig");

    // Notes (comment-based)
    _ = @import("notes/comments.zig");
    _ = @import("notes/commands.zig");

    // LSP server
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/diagnostics.zig");
    _ = @import("lsp/server.zig");
}
