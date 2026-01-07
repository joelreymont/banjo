---
title: Add test coverage for commands.lua
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T11:36:45.944958+02:00"
closed-at: "2026-01-06T11:46:44.915519+02:00"
---

File: nvim/lua/banjo/commands.lua - No test coverage. Need to test slash command registration, handlers, and completion. Commands include /model, /permission-mode, /session-clear, etc. Should verify command dispatch, argument parsing, and edge cases.
