---
title: Bridge queue bounds
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-16T22:16:35.824360+02:00\""
closed-at: "2026-01-16T22:42:59.520796+02:00"
close-reason: completed
---

Full context: src/core/claude_bridge.zig:547-977 and src/core/codex_bridge.zig:538-859 unbounded queues; add max queue size + backpressure/limits.
