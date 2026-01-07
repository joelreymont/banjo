---
title: Implement MCP tool handlers
status: closed
priority: 2
issue-type: task
created-at: "2026-01-05T11:41:02.786960+02:00"
closed-at: "2026-01-05T20:11:22.294114+02:00"
---

In nvim/mcp_server.zig implement MCP tool handlers: getCurrentSelection, getOpenEditors, getDiagnostics, openFile, openDiff. Forward requests to Lua via stdout, wait for response on stdin.
