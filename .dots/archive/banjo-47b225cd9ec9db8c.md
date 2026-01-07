---
title: "P0-4: Add autocmd cleanup tests"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T08:18:44.247255+02:00"
closed-at: "2026-01-06T08:21:22.210968+02:00"
---

File: nvim/tests/bridge_spec.lua - TabClosed autocmd had syntax error but tests don't execute autocmds. Need test that creates tab, closes it, verifies cleanup without errors.
