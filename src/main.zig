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
    output_format: Format = .stream_json,
    input_format: Format = .stream_json,
    verbose: bool = false,
    session_id: ?[]const u8 = null,
    permission_mode: []const u8 = "default",
    allowed_tools: ?[]const u8 = null,
    disallowed_tools: ?[]const u8 = null,
    mcp_config: ?[]const u8 = null,
    include_partial_messages: bool = false,
    allow_dangerously_skip_permissions: bool = false,

    const Format = enum { stream_json, text };
};

const ArgAction = enum {
    mode_agent,
    mode_lsp,
    output_format,
    input_format,
    verbose,
    session_id,
    permission_mode,
    allowed_tools,
    disallowed_tools,
    mcp_config,
    include_partial_messages,
    allow_dangerously_skip_permissions,
    permission_prompt_tool,
    setting_sources,
    print,
    help,
};

const arg_map = std.StaticStringMap(ArgAction).initComptime(.{
    .{ "--agent", .mode_agent },
    .{ "--lsp", .mode_lsp },
    .{ "--output-format", .output_format },
    .{ "--input-format", .input_format },
    .{ "--verbose", .verbose },
    .{ "-v", .verbose },
    .{ "--session-id", .session_id },
    .{ "--permission-mode", .permission_mode },
    .{ "--allowedTools", .allowed_tools },
    .{ "--disallowedTools", .disallowed_tools },
    .{ "--mcp-config", .mcp_config },
    .{ "--include-partial-messages", .include_partial_messages },
    .{ "--allow-dangerously-skip-permissions", .allow_dangerously_skip_permissions },
    .{ "--permission-prompt-tool", .permission_prompt_tool },
    .{ "--setting-sources", .setting_sources },
    .{ "-p", .print },
    .{ "--print", .print },
    .{ "-h", .help },
    .{ "--help", .help },
});

const format_map = std.StaticStringMap(CliOptions.Format).initComptime(.{
    .{ "stream-json", .stream_json },
    .{ "text", .text },
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
            .output_format => opts.output_format = parseFormat(args.next()),
            .input_format => opts.input_format = parseFormat(args.next()),
            .verbose => opts.verbose = true,
            .session_id => opts.session_id = args.next(),
            .permission_mode => opts.permission_mode = args.next() orelse "default",
            .allowed_tools => opts.allowed_tools = args.next(),
            .disallowed_tools => opts.disallowed_tools = args.next(),
            .mcp_config => opts.mcp_config = args.next(),
            .include_partial_messages => opts.include_partial_messages = true,
            .allow_dangerously_skip_permissions => opts.allow_dangerously_skip_permissions = true,
            .permission_prompt_tool, .setting_sources, .print => _ = args.next(),
            .help => {
                printHelp();
                std.process.exit(0);
            },
        }
    }

    return opts;
}

fn parseFormat(val: ?[]const u8) CliOptions.Format {
    return if (val) |v| format_map.get(v) orelse .text else .stream_json;
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
        \\  --output-format <format>    Output format: stream-json, text
        \\  --input-format <format>     Input format: stream-json, text
        \\  --verbose                   Enable verbose logging
        \\  --session-id <id>           Session ID for resuming
        \\  --permission-mode <mode>    Permission mode: default, plan, etc.
        \\  --allowedTools <tools>      Comma-separated allowed tools
        \\  --disallowedTools <tools>   Comma-separated disallowed tools
        \\  --mcp-config <json>         MCP server configuration
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
            log.info("Banjo LSP v{s} ({s}) starting", .{ config.version, config.git_hash });
            var server = LspServer.init(allocator, stdin, stdout);
            defer server.deinit();
            try server.run();
        },
        .agent => {
            log.info("Banjo Agent v{s} ({s}) starting", .{ config.version, config.git_hash });
            if (opts.verbose) {
                if (opts.session_id) |sid| {
                    log.info("Session ID: {s}", .{sid});
                }
            }

            var reader = jsonrpc.Reader.init(allocator, stdin);
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
