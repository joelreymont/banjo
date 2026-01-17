---
title: Permission socket DRY
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-16T22:16:35.830506+02:00\""
closed-at: "2026-01-16T22:42:59.527416+02:00"
close-reason: completed
---

Full context: src/acp/agent.zig:2741-2860 and src/ws/handler.zig:405-555 duplicate socket read/parse/response; move shared read/response/types into src/core/permission_socket.zig, align response schema with main.zig.
