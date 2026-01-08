---
title: Fix blocking I/O in pollPermissionSocket
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-08T15:18:18.892180+02:00\\\"\""
closed-at: "2026-01-08T15:37:30.873969+02:00"
close-reason: Replaced sleep-based polling with std.posix.poll() in pollPermissionSocket
---

Fixing permission socket blocking
