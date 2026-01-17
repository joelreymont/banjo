---
title: Buffered JSON-RPC reader
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-01-16T22:08:13.610447+02:00\\\"\""
closed-at: "2026-01-16T22:42:59.508917+02:00"
close-reason: completed
---

Full context: src/jsonrpc.zig:422,447 readByte loop; too many syscalls. Fix: replace with buffered line reader using ByteQueue + chunked reads; add tests for multi-line and partial reads.
