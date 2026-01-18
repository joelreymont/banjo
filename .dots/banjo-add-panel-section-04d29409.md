---
title: Add panel section model
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.303340+02:00"
---

Full context:
- Files to modify: nvim/lua/banjo/panel.lua:51-83; add new nvim/lua/banjo/ui/sections.lua
- What to change: define section layout model (header/action/history/input) stored in per-tab state; helper to compute section ranges and re-render without recreating buffers.
- Dependencies: banjo-neogit-style-nvim-302f6906
- Verification: nvim/tests/panel_spec.lua, nvim/tests/panel_e2e_spec.lua
