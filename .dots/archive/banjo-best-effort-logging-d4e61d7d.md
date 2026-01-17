---
title: Best-effort logging
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-16T22:16:35.817039+02:00\\\"\""
closed-at: "2026-01-16T22:42:59.513436+02:00"
close-reason: completed
---

Full context: src/main.zig:27-31 and src/util/log.zig:118-153 panic on log formatting/writes; change to best-effort logging that never panics.
