---
title: Wire auth action keymaps
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.315202+02:00"
---

Full context:
- Files to modify: nvim/lua/banjo/panel.lua:520-590 (output keymaps), nvim/lua/banjo/commands.lua:135-182
- What to change: bind header action keys to mode/agent/model setters; reuse commands API for /mode, /claude, /codex.
- Dependencies: banjo-add-auth-action-b77ef599
- Verification: nvim/tests/commands_spec.lua, nvim/tests/panel_e2e_spec.lua
