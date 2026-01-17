---
title: Fence parsing from stream chunks
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-17T07:13:27.533212+02:00\\\"\""
closed-at: "2026-01-17T07:17:56.102985+02:00"
close-reason: completed
---

Full context: nvim/lua/banjo/panel.lua:969-999, 1028-1077. Cause: streaming deltas split fences; current finder misses closing at start and open+close same chunk. Fix: incremental line-based fence tracker with partial-line state + correct open/close handling.
