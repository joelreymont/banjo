---
title: Render header section
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:35:53.308427+02:00"
---

Full context:
- Files to modify: nvim/lua/banjo/panel.lua:127-220, 1323-1394, 660-661
- What to change: render a fixed header section in the output buffer (agent + auth mode), remove winbar status usage, update _build_status/_update_status to rewrite header lines.
- Dependencies: banjo-neogit-style-nvim-302f6906, banjo-add-panel-section-04d29409
- Verification: nvim/tests/panel_spec.lua, nvim/tests/panel_e2e_spec.lua
