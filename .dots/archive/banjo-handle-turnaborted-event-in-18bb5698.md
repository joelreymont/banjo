---
title: Handle TurnAborted event in Codex bridge
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:44.505926+02:00\""
closed-at: "2026-01-11T12:39:45.923252+02:00"
---

Add TurnAborted to CodexMessage event types. Parse TurnAbortReason (Interrupted/Replaced/ReviewEnded). On TurnAborted, set turn complete flag, notify nvim of cancellation. Ignore late deltas for mismatched turn_id. See protocol.rs:1924
