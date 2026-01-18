---
title: Wire auth menu actions
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T17:02:52.194314+02:00\""
closed-at: "2026-01-18T21:46:24.298133+02:00"
close-reason: completed
blocks:
  - banjo-render-auth-menu-1a6a08b4
---

Full context: nvim/lua/banjo/panel.lua:98-205, 672-720 (keymaps/focus), nvim/lua/banjo/bridge.lua:845-854 (set_permission_mode). Root cause: mode changes only via commands/prompt. Fix: add keymaps/click handlers to set mode from header menu and update state; sync bridge state. Why: inline UX without dialogs. Verification: panel_spec.lua new tests for mode toggle -> bridge.set_permission_mode called.
