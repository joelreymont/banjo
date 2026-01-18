---
title: Define neogit layout
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T17:02:32.458598+02:00"
---

Full context: nvim/lua/banjo/panel.lua:1-220, 600-720, 1323-1388. Root cause: UI layout is implicit and split-window; no explicit section model. Fix: define section model (Header/Auth, History, Input, Actions) and buffer layout contract; decide single-buffer vs split and scrolling rules. Why: enables inline menu and consistent UX. Verification: document layout in code comments + adjust tests plan.
