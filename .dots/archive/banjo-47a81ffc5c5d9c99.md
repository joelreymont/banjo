---
title: "Phase 3.2: Persist on disconnect"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T20:21:16.974179+02:00"
closed-at: "2026-01-05T20:56:53.429683+02:00"
---

File: nvim/lua/banjo/bridge.lua. On _on_exit, call sessions.save(session_id, {history, input_text, timestamp}). < 10 min.
