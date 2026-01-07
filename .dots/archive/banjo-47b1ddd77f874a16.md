---
title: "Switch to plenary: Fix init_spec.lua lifecycle hooks"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T07:58:36.935055+02:00"
closed-at: "2026-01-06T08:05:57.553698+02:00"
---

File: nvim/tests/init_spec.lua - Verify before_each/after_each work with plenary (lines 7-33). Ensure keymap/command cleanup actually runs between tests. Add async.it() for tests that need wait_for.
