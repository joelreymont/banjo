---
title: "Phase 1.4: Implement auto-scroll with manual pause"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T20:12:40.718569+02:00"
closed-at: "2026-01-05T20:20:25.697222+02:00"
---

File: src/tui/main.zig. Auto-scroll to bottom on new content, pause when user scrolls up (detect scroll position != bottom), resume on scroll-to-bottom or new input. Add visual indicator for paused state.
