---
title: Track turn_id in Codex bridge
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:44.719505+02:00\""
closed-at: "2026-01-11T12:56:09.328033+02:00"
---

Store current_turn_id in CodexBridge state. Set on turn/start response (TurnStartResponse has turn with id). Clear on TurnAborted/TurnCompleted. Use for interrupt requests and delta correlation.
