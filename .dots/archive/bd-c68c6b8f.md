---
title: "P0: Memory leak in agent.zig:437-444 - handleResumeSession creates new Session without checking existing. Fix: use getOrPut"
status: closed
priority: 0
issue-type: task
created-at: "2025-12-25T07:09:04.053141+02:00"
closed-at: "2025-12-25T07:32:31.951850+02:00"
close-reason: "Fixed: check for existing session before creating new"
---
