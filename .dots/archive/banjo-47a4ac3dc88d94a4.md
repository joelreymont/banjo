---
title: Integrate mcp_server into handler.zig
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T16:14:10.202773+02:00"
closed-at: "2026-01-05T16:36:32.572444+02:00"
---

File: src/nvim/handler.zig - Add McpServer to NvimHandler. Start server on init, write lock file. Add poll() loop for stdin + WebSocket fd. Clean up lock file on shutdown.
