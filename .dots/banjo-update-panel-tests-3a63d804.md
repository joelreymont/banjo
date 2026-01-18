---
title: Update panel tests
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.323825+02:00"
---

Full context:
- Files to modify: nvim/tests/panel_spec.lua:1-220, nvim/tests/panel_e2e_spec.lua, nvim/tests/commands_spec.lua
- What to change: update expectations for header/action row and layout; add assertions for keymap actions.
- Dependencies: banjo-render-header-section-902d664d, banjo-wire-auth-action-f951738c
- Verification: nvim/tests/run.lua
