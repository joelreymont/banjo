const std = @import("std");

pub const markers = [_][]const u8{ "/login", "login", "log in", "authenticate" };

pub fn containsAuthMarker(text: []const u8) bool {
    for (markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(text, marker) != null) return true;
    }
    return false;
}

test "containsAuthMarker detects auth markers case-insensitively" {
    const ohsnap = @import("ohsnap");
    const summary = .{
        .login = containsAuthMarker("Please LOGIN to continue"),
        .authenticate = containsAuthMarker("Authenticate to proceed"),
        .clean = containsAuthMarker("All good here"),
    };
    try (ohsnap{}).snap(@src(),
        \\core.auth_markers.test.containsAuthMarker detects auth markers case-insensitively__struct_<^\d+$>
        \\  .login: bool = true
        \\  .authenticate: bool = true
        \\  .clean: bool = false
    ).expectEqual(summary);
}
