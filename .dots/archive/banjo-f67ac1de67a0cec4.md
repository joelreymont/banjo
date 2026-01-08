---
title: Fix memory leak in cbOnApprovalRequest - clarify response ownership
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-08T15:18:18.892180+02:00\\\"\""
closed-at: "2026-01-08T15:37:43.755070+02:00"
close-reason: Used StaticStringMap with string literals for decisions, avoiding allocations
---

Fixing approval response leak
