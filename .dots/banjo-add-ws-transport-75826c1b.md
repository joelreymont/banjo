---
title: Add ws_transport WsWriter buffer test
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T18:55:07.401024+02:00"
---

src/acp/ws_transport.zig: Add property test for WsWriter buffering until newline. Multiple writes accumulate, newline triggers frame send.
