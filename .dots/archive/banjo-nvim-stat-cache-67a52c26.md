---
title: Nvim stat cache refine
status: closed
priority: 3
issue-type: task
created-at: "\"\\\"2026-01-17T07:29:19.657096+02:00\\\"\""
closed-at: "2026-01-17T07:32:09.519462+02:00"
close-reason: completed
---

Full context: nvim/lua/banjo/panel.lua:1601-1626. Cause: stat cache stores negatives and grows with unique misses. Fix: cache only positives; keep size bounded.
