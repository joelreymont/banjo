const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const Agent = @import("acp/agent.zig").Agent;

const log = std.log.scoped(.banjo);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.info("Banjo ACP agent starting...", .{});

    const stdin = std.fs.File.stdin().deprecatedReader().any();
    const stdout = std.fs.File.stdout().deprecatedWriter().any();

    var reader = jsonrpc.Reader.init(allocator, stdin);
    defer reader.deinit();

    var acp_agent = Agent.init(allocator, stdout);
    defer acp_agent.deinit();

    // Main event loop
    while (true) {
        var parsed = reader.next() catch |err| {
            log.err("Failed to parse request: {}", .{err});
            continue;
        } orelse {
            log.info("EOF received, shutting down", .{});
            break;
        };
        defer parsed.deinit();

        acp_agent.handleRequest(parsed.request) catch |err| {
            log.err("Failed to handle request: {}", .{err});
        };
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
    _ = @import("settings/loader.zig");
    _ = @import("tools/proxy.zig");
    _ = @import("util/quickcheck.zig");
}
