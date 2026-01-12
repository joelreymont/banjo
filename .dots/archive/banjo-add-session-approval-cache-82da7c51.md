---
title: Add session approval cache
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:59.560028+02:00\""
closed-at: "2026-01-11T12:44:48.178590+02:00"
---

Cache ApprovedForSession decisions per command hash in handler.zig. Check cache before showing prompt. Store command tokens + cwd. Clear on session end. Avoid repetitive prompts for same command.
