---
title: Extract callback context helper
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T16:00:39.827499+02:00\""
closed-at: "2026-01-08T16:15:49.206356+02:00"
close-reason: Added inline from() helper to CallbackContext and PromptCallbackContext
---

handler.zig and agent.zig repeat @ptrCast(@alignCast(ctx)) ~20 times. Create inline helper function
