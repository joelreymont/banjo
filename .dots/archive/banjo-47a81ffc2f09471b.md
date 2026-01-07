---
title: "Phase 3.1: Send session lifecycle events"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T20:21:16.962579+02:00"
closed-at: "2026-01-05T20:54:03.619816+02:00"
---

File: src/nvim/handler.zig. On first prompt, emit session_start. On cancel/new, emit session_end. Propagate to MCP. < 15 min.
