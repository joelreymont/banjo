---
title: Create NudgeState struct
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T15:30:44.981936+02:00\""
closed-at: "2026-01-08T15:37:11.995250+02:00"
close-reason: Created NudgeState struct with enabled bool and last_ms timestamp
---

File: src/nvim/handler.zig - Extract nudge-related fields from Handler into NudgeState struct: nudge_enabled, last_nudge_ms. Simple value struct, no methods needed.
