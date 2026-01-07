---
title: Create nvim/mcp_server.zig
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T11:40:59.476713+02:00"
closed-at: "2026-01-05T20:11:22.290040+02:00"
---

Create src/nvim/mcp_server.zig - WebSocket MCP server for Claude CLI. TCP listener on random port, HTTP upgrade, WebSocket framing. Write lock file to ~/.claude/ide/[port].lock with JSON: pid, ideName, transport, port, workspaceFolders, authToken. ~400 lines.
