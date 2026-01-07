---
title: "P3: jsonrpc.zig:204-215 reads byte-by-byte. Use buffered reader"
status: closed
priority: 3
issue-type: task
created-at: "2025-12-25T07:09:04.074365+02:00"
closed-at: "2025-12-25T07:36:38.069071+02:00"
close-reason: "Won't fix: Reader takes AnyReader (type-erased), buffering must be done by caller. main.zig already uses deprecatedReader which internally buffers."
---
