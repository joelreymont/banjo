---
title: Create websocket.zig - HTTP upgrade handshake
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T16:14:01.043456+02:00"
closed-at: "2026-01-05T16:36:19.329397+02:00"
---

File: src/nvim/websocket.zig - Parse HTTP upgrade request, validate Sec-WebSocket-Key, compute accept hash (SHA1+base64), send 101 response. Validate x-claude-code-ide-authorization header.
