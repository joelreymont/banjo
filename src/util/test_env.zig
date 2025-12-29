const std = @import("std");
const Allocator = std.mem.Allocator;
const c_stdlib = @cImport({
    @cInclude("stdlib.h");
});

pub const EnvVarGuard = struct {
    name: [:0]const u8,
    previous: ?[]u8,
    allocator: Allocator,

    pub fn set(allocator: Allocator, name: [:0]const u8, value: ?[]const u8) !EnvVarGuard {
        var guard = EnvVarGuard{
            .name = name,
            .previous = null,
            .allocator = allocator,
        };

        if (std.posix.getenv(name)) |prev| {
            guard.previous = try allocator.dupe(u8, std.mem.sliceTo(prev, 0));
        }

        if (value) |val| {
            const val_z = try allocator.allocSentinel(u8, val.len, 0);
            std.mem.copyForwards(u8, val_z[0..val.len], val);
            defer allocator.free(val_z);
            _ = c_stdlib.setenv(name, val_z, 1);
        } else {
            _ = c_stdlib.unsetenv(name);
        }

        return guard;
    }

    pub fn deinit(self: *EnvVarGuard) void {
        if (self.previous) |prev| {
            const prev_z = self.allocator.allocSentinel(u8, prev.len, 0) catch {
                self.allocator.free(prev);
                _ = c_stdlib.unsetenv(self.name);
                return;
            };
            std.mem.copyForwards(u8, prev_z[0..prev.len], prev);
            _ = c_stdlib.setenv(self.name, prev_z, 1);
            self.allocator.free(prev_z);
            self.allocator.free(prev);
        } else {
            _ = c_stdlib.unsetenv(self.name);
        }
    }
};
