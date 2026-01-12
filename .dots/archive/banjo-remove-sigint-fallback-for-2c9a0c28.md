---
title: Remove SIGINT fallback for Claude
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:32:12.990886+02:00\""
closed-at: "2026-01-11T12:55:02.180708+02:00"
---

SIGINT is the ONLY way to interrupt Claude Code CLI - no JSON control messages supported. Keep interrupt() for Claude, remove for Codex. Document difference in comments.
