const std = @import("std");

pub const Engine = enum {
    claude,
    codex,

    pub fn label(self: Engine) []const u8 {
        return switch (self) {
            .claude => "Claude",
            .codex => "Codex",
        };
    }

    pub fn prefix(self: Engine) []const u8 {
        return switch (self) {
            .claude => "[Claude] ",
            .codex => "[Codex] ",
        };
    }
};

pub const Route = enum {
    claude,
    codex,
    duet,
};

pub const route_map = std.StaticStringMap(Route).initComptime(.{
    .{ "claude", .claude },
    .{ "codex", .codex },
    .{ "duet", .duet },
});

pub const engine_map = std.StaticStringMap(Engine).initComptime(.{
    .{ "claude", .claude },
    .{ "codex", .codex },
});

pub fn routeFromEnv() Route {
    const val = std.posix.getenv("BANJO_ROUTE") orelse return .claude;
    return route_map.get(val) orelse .claude;
}
