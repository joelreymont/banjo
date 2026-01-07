---
title: Add test coverage for WebSocket modules
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T11:36:56.085383+02:00"
closed-at: "2026-01-06T11:42:31.246051+02:00"
---

Files: nvim/lua/banjo/websocket/client.lua, frame.lua, utils.lua - No test coverage. Critical modules for backend communication. Need to test: connection lifecycle, frame encoding/decoding, error handling, message parsing, and reconnection logic.
