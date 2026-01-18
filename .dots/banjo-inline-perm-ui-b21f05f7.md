---
title: Inline permission UI
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.320912+02:00"
---

Full context:
- Files to modify: nvim/lua/banjo/ui/prompt.lua:1-220, nvim/lua/banjo/panel.lua (new entry point)
- What to change: replace nui popup permission/approval with inline menu in panel header/action row; route callbacks through panel.
- Dependencies: banjo-add-auth-action-b77ef599
- Verification: nvim/tests/panel_e2e_spec.lua (permission flow), nvim/tests/commands_spec.lua
