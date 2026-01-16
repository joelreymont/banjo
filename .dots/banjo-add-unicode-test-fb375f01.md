---
title: Add unicode test overlong encoding
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T18:56:26.349054+02:00"
---

src/jsonrpc.zig: Add test - overlong NUL (0xC0 0x80) rejected or handled safely.
