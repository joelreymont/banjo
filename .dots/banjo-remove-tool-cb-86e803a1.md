---
title: Remove tool callback from server
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T17:16:24.367887+02:00"
---

src/nvim/mcp_server.zig:51-53: Remove tool_request_callback, tool_callback_ctx. Remove pending_tool_requests hashmap and PendingToolRequest struct:82-93
