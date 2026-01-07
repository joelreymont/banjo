---
title: "Switch to plenary: Fix bridge_spec.lua lifecycle hooks"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T07:58:36.551093+02:00"
closed-at: "2026-01-06T08:05:57.550172+02:00"
---

File: nvim/tests/bridge_spec.lua - Verify before_each/after_each work correctly with plenary (lines 7-14). Test that module reloading and cleanup actually execute. Current custom framework has these as no-ops.
