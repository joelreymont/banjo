---
title: Share session ID generation
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T16:00:21.678281+02:00\""
closed-at: "2026-01-08T16:15:16.235068+02:00"
close-reason: Verified - different formats for different purposes, no sharing needed
---

handler.zig:176-181 and lockfile.zig:64-85 have duplicated UUID/session ID generation. Create shared utility
