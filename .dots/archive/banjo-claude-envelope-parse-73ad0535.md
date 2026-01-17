---
title: Claude envelope parse handling
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-16T22:16:35.827394+02:00\""
closed-at: "2026-01-16T22:42:59.524141+02:00"
close-reason: completed
---

Full context: src/core/claude_bridge.zig:239-246 panics on parse error; return null + log instead.
