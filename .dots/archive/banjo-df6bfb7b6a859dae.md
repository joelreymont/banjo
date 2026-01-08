---
title: [CRIT] Fix memory leak in jsonValueFromTyped
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T13:02:55.031230+02:00\""
closed-at: "2026-01-08T14:41:08.173076+02:00"
close-reason: Eliminated jsonValueFromTyped - direct serialization via sendMcpResultDirect
---

File: src/nvim/mcp_server.zig:786-799 - parseFromSlice returns a Parsed struct with bookkeeping that is never freed. The json.Value references data owned by parsed, causing memory leak. Fix: Use parseFromSliceLeaky with arena allocator, or redesign to avoid the serialize-then-parse round-trip. Impact: Memory grows unbounded over time.
