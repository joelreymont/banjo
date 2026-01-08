---
title: Extract common bridge message queue infrastructure
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T13:03:35.192081+02:00\""
closed-at: "2026-01-08T14:43:18.605852+02:00"
close-reason: Low priority refactor - deferring
---

Files: src/core/claude_bridge.zig:781-809, src/core/codex_bridge.zig:586-614 - Both bridges have nearly identical popMessage implementations with mutex/condition pattern. Fix: Create BridgeQueue(MessageType) generic or extract MessageQueue struct to src/core/queue.zig. Impact: Reduces parallel maintenance burden, ensures consistent queue behavior.
