---
title: Create nvim/protocol.zig
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T11:40:45.523091+02:00"
closed-at: "2026-01-05T20:11:22.278262+02:00"
---

Create src/nvim/protocol.zig with stdio JSON protocol types. Request union: prompt, selection_changed, nudge_toggle, cancel. Notification union: stream_chunk, status, request_permission, open_diff. ~100 lines.
