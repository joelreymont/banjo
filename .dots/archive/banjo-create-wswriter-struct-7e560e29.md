---
title: Create WsWriter struct
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T17:16:35.975260+02:00\""
closed-at: "2026-01-16T18:01:58.690932+02:00"
---

src/acp/ws_transport.zig (new): Create WsWriter with socket+mutex, writer() returns AnyWriter, writeFn wraps bytes in WebSocket text frame
