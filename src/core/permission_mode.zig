const std = @import("std");
const testing = std.testing;
const ohsnap = @import("ohsnap");

pub const PermissionMode = enum {
    default,
    acceptEdits,
    bypassPermissions,
    dontAsk,
    plan,

    pub fn toString(self: PermissionMode) []const u8 {
        return switch (self) {
            .default => "Default",
            .acceptEdits => "Accept Edits",
            .bypassPermissions => "Auto-approve",
            .dontAsk => "Don't Ask",
            .plan => "Plan Only",
        };
    }

    pub fn toCliFlag(self: PermissionMode) ?[]const u8 {
        return switch (self) {
            .default => null,
            .acceptEdits => "--allowedTools",
            .bypassPermissions, .dontAsk => "--dangerouslySkipPermissions",
            .plan => "--plan",
        };
    }

    /// Returns the value for --permission-mode CLI arg, or null for default.
    pub fn toCliArg(self: PermissionMode) ?[]const u8 {
        return switch (self) {
            .default => null,
            .acceptEdits => "acceptEdits",
            .bypassPermissions => "bypassPermissions",
            .dontAsk => "dontAsk",
            .plan => "plan",
        };
    }

    /// Returns the Codex approvalPolicy value, or null for default (on-request).
    pub fn toCodexApprovalPolicy(self: PermissionMode) ?[]const u8 {
        return switch (self) {
            .default, .plan => null, // on-request (interactive)
            .acceptEdits => "auto-edit", // auto-approve edits only
            .bypassPermissions, .dontAsk => "full-auto", // auto-approve everything
        };
    }
};

test "PermissionMode mappings snapshot" {
    const modes = [_]PermissionMode{
        .default,
        .acceptEdits,
        .bypassPermissions,
        .dontAsk,
        .plan,
    };

    var out: std.io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    for (modes) |mode| {
        const cli_flag = mode.toCliFlag() orelse "null";
        const cli_arg = mode.toCliArg() orelse "null";
        const policy = mode.toCodexApprovalPolicy() orelse "null";
        try out.writer.print(
            "mode: {s}\nlabel: {s}\ncli_flag: {s}\ncli_arg: {s}\ncodex_policy: {s}\n\n",
            .{ @tagName(mode), mode.toString(), cli_flag, cli_arg, policy },
        );
    }

    const snapshot = try out.toOwnedSlice();
    defer testing.allocator.free(snapshot);

    try (ohsnap{}).snap(@src(),
        \\mode: default
        \\label: Default
        \\cli_flag: null
        \\cli_arg: null
        \\codex_policy: null
        \\
        \\mode: acceptEdits
        \\label: Accept Edits
        \\cli_flag: --allowedTools
        \\cli_arg: acceptEdits
        \\codex_policy: null
        \\
        \\mode: bypassPermissions
        \\label: Auto-approve
        \\cli_flag: --dangerouslySkipPermissions
        \\cli_arg: bypassPermissions
        \\codex_policy: never
        \\
        \\mode: dontAsk
        \\label: Don't Ask
        \\cli_flag: --dangerouslySkipPermissions
        \\cli_arg: dontAsk
        \\codex_policy: never
        \\
        \\mode: plan
        \\label: Plan Only
        \\cli_flag: --plan
        \\cli_arg: plan
        \\codex_policy: null
        \\
        \\
    ).diff(snapshot, true);
}
