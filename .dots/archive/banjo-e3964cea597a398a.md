---
title: Integrate new state structs into Handler
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T15:30:47.118823+02:00\""
closed-at: "2026-01-08T15:37:13.369367+02:00"
close-reason: Handler now uses permission, approval, prompt, nudge state structs; all references updated
---

File: src/nvim/handler.zig - Replace individual fields in Handler with PermissionState, ApprovalState, PromptState, NudgeState. Update all field access sites. Run tests.
