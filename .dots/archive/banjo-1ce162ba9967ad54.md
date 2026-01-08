---
title: Unify permission mode enums
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T16:00:13.431556+02:00\""
closed-at: "2026-01-08T16:15:06.402323+02:00"
close-reason: Verified intentional design - ACP uses spec naming, nvim has conversion methods
---

protocol.zig:576-582 has ACP PermissionMode, nvim/protocol.zig has different enum with different names (acceptEdits vs accept_edits). Create shared enum in core/types.zig with conversion methods
