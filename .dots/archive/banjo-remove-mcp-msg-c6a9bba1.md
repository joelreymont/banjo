---
title: Remove MCP message handlers
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-16T17:16:14.109639+02:00\\\"\""
closed-at: "2026-01-16T17:51:25.605423+02:00"
---

src/nvim/mcp_server.zig:508-563,648-887: Remove handleMcpClientMessage, handleMcpJsonRpcMessage, handleInitialize, handleToolsList, handleToolsCall, handleLocalTool, sendMcp* methods
