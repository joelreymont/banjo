---
title: Engine loop refactor
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-16T22:16:35.833877+02:00\""
closed-at: "2026-01-16T22:42:59.536255+02:00"
close-reason: completed
---

Full context: src/core/engine.zig:159-700 duplicated control flow between Claude/Codex loops; extract shared helpers to reduce duplication and improve clarity.
