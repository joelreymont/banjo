---
title: Neogit-style Nvim UI
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T17:02:25.244434+02:00"
---

Context: nvim/lua/banjo/panel.lua:1-1405 + nvim/tests/panel_spec.lua:1-200. Root cause: Banjo panel is split-window with modal prompts; auth mode not inline. Fix: redesign panel to neogit-like sections with inline auth menu, history-first layout, and keymaps; update tests/docs.
