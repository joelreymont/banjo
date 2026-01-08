---
title: [HIGH] Extract shared debug logging module
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T13:03:09.990319+02:00\""
closed-at: "2026-01-08T14:38:32.975405+02:00"
close-reason: Created util/debug_log.zig with shared DebugLog
---

Files: engine.zig:24-35, claude_bridge.zig:13-24, handler.zig:24-40, mcp_server.zig:15-26 - Four nearly identical debug logging functions with different prefixes. Fix: Create src/core/debug.zig with parameterized debugLog(prefix, fmt, args) function. Impact: Reduces code duplication, ensures consistent behavior.
