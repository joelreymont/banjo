---
title: Rework panel layout
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.317995+02:00"
---

Full context:
- Files to modify: nvim/lua/banjo/panel.lua:617-657, 732-780
- What to change: ensure history renders above prompt with fixed input window; adjust scrolling to keep header+history visible; preserve focus behavior.
- Dependencies: banjo-add-panel-section-04d29409
- Verification: nvim/tests/panel_spec.lua (window count), nvim/tests/e2e_input_spec.lua
