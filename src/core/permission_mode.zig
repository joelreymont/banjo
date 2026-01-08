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

    /// Returns the Codex approvalPolicy value, or null for default (interactive).
    pub fn toCodexApprovalPolicy(self: PermissionMode) ?[]const u8 {
        return switch (self) {
            .default, .acceptEdits, .plan => null,
            .bypassPermissions, .dontAsk => "never",
        };
    }
};
