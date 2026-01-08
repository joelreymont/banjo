---
title: [HIGH] Make debug buffers thread-safe
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T13:03:13.080837+02:00\""
closed-at: "2026-01-08T14:43:22.067584+02:00"
close-reason: Debug logging rarely used concurrently - deferring
---

Files: engine.zig:24, claude_bridge.zig:13, handler.zig:25, mcp_server.zig:15 - Global mutable [4096]u8 buffers could corrupt under concurrent access. Fix: In shared debug module, use thread-local storage or mutex-protected buffer pool. Depends on: Extract shared debug logging module. Impact: Prevents debug output corruption in multi-threaded scenarios.
