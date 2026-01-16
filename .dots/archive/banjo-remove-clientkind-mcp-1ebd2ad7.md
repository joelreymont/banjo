---
title: Remove ClientKind.mcp from websocket
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T17:16:12.729521+02:00\""
closed-at: "2026-01-16T17:46:46.069719+02:00"
---

src/nvim/websocket.zig:207-209: Remove mcp variant from ClientKind enum. Update completeHandshake:85-98 to remove /mcp path detection and auth validation
