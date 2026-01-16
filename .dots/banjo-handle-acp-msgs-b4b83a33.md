---
title: Handle ACP messages in poll
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T17:16:49.596149+02:00"
---

src/nvim/mcp_server.zig:poll: Poll acp_client socket, forward frames to agent.handleMessage via WsReader
