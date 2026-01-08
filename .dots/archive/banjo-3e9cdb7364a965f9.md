---
title: [HIGH] Cache debug log file handle
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T13:03:12.024797+02:00\""
closed-at: "2026-01-08T14:42:43.538933+02:00"
close-reason: Covered by util/debug_log.zig with cached file handle
---

Files: All debug logging functions - Currently opens, seeks, writes, syncs, closes file on every log call. Fix: In the shared debug module, open file once at init, keep handle, use buffered writes. Depends on: Extract shared debug logging module. Impact: Reduces I/O overhead when debug enabled.
