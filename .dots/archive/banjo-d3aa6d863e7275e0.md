---
title: Optimize JSON parsing in sendEngineToolCall
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T16:00:17.546061+02:00\""
closed-at: "2026-01-08T16:15:12.144965+02:00"
close-reason: Already optimized - isQuiet check returns early before JSON parsing
---

agent.zig:2030-2046 parses JSON input on every tool call for preview. Check isQuiet first before parsing to avoid unnecessary allocations
