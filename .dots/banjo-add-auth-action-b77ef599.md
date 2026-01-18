---
title: Add auth action row
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.311961+02:00"
---

Full context:
- Files to modify: nvim/lua/banjo/panel.lua:1323-1370, 520-590 (highlights)
- What to change: add inline horizontal auth/action menu below header (mode/agent/model + key hints), highlight groups for buttons/state.
- Dependencies: banjo-render-header-section-902d664d
- Verification: nvim/tests/panel_spec.lua (rendered header lines), nvim/tests/panel_e2e_spec.lua
