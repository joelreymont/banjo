---
title: Track item_id for streaming deltas
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:32:12.782480+02:00\""
closed-at: "2026-01-11T12:54:43.906280+02:00"
---

Codex AgentMessageContentDeltaEvent has turn_id+item_id (protocol.rs:778). Track items by item_id in bridge. Correlate deltas to correct item. Send structured updates to panel.
