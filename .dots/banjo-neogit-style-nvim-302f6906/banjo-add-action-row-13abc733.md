---
title: Add action row + hints
status: open
priority: 2
issue-type: task
created-at: "2026-01-18T17:03:08.959823+02:00"
blocks:
  - banjo-define-neogit-layout-335eb23d
---

Full context: nvim/lua/banjo/panel.lua:1323-1388, 208-216 (command args). Root cause: actions hidden behind commands; no inline hint row. Fix: render actions row (prompt/cancel/nudge/mode/engine/model) with key hints; keep consistent with neogit. Why: discoverability. Verification: panel_spec.lua checks action row text/hl.
