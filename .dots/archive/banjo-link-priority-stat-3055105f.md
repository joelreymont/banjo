---
title: Link priority + stat cache
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T07:13:31.622017+02:00\\\"\""
closed-at: "2026-01-17T07:17:59.771936+02:00"
close-reason: completed
---

Full context: nvim/lua/banjo/panel.lua:1606-1795. Cause: file extmarks can shadow URLs; fs_stat per match on hot path. Fix: select URL over file when overlapping; add small stat cache to avoid repeated fs_stat.
