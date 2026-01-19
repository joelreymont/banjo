---
title: Add section layout model
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T17:12:00.911162+02:00\""
closed-at: "2026-01-18T21:11:12.229225+02:00"
---

File: nvim/lua/banjo/panel.lua:50-120. Root cause: no explicit section model for header/history/input/actions. Fix: introduce section descriptors + render order constants; document scroll rules. Why: enables neogit-style inline UI.
