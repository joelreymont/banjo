---
title: Remove mcp_client from server
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T17:16:13.426799+02:00"
---

src/nvim/mcp_server.zig:26,41: Remove mcp_client_socket field and mcp_read_buffer. Remove closeMcpClient:296-304
