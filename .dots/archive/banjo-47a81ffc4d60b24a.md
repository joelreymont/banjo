---
title: "Phase 3.2: Create session store module"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T20:21:16.970347+02:00"
closed-at: "2026-01-05T20:56:28.183246+02:00"
---

File: nvim/lua/banjo/sessions.lua. New module. save(id, data) writes to stdpath('data')/sessions/{id}.json. load(id) reads. < 15 min.
