---
title: Optimize cbSendToolCall allocations
status: completed
priority: 2
issue-type: task
created-at: "\"2026-01-08T16:01:12.007425+02:00\""
---

Fixed: reduced tool call input allocations with a stack buffer + fallback at `src/nvim/handler.zig:1107`.
