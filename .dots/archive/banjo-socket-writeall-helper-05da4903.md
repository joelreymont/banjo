---
title: Socket writeAll helper
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-16T22:16:35.820848+02:00\""
closed-at: "2026-01-16T22:42:59.517586+02:00"
close-reason: completed
---

Full context: src/main.zig:355, src/ws/handler.zig:653, src/acp/agent.zig:2857/2882, src/acp/ws_transport.zig:60-65, src/ws/websocket.zig:320-326 and other posix.write sites; add io_utils.writeAll and replace single writes to handle partial writes.
