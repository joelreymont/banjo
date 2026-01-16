---
title: Remove auth_token from server init
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T17:16:26.005959+02:00"
---

src/nvim/mcp_server.zig:30,125-126,133: Remove auth_token field and generation. Update lockfile.create call
