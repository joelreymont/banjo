---
title: "Phase 1.4: Add auto-scroll logic"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T20:20:49.255407+02:00"
closed-at: "2026-01-05T20:34:27.243600+02:00"
---

File: nvim/lua/banjo/panel.lua. After appending chunk, if os.time() - last_scroll_time > 2, scroll to bottom. Else preserve position. < 15 min.
