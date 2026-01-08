---
title: Fix debug buffer race condition
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-08T14:57:01.285827+02:00\""
closed-at: "2026-01-08T14:59:51.962464+02:00"
close-reason: Fixed - use stack-allocated buffers instead of globals
---

Files: engine.zig:24, claude_bridge.zig:13, handler.zig:27 - Global mutable debug buffers without synchronization. Fix: use stack-allocated buffers instead
