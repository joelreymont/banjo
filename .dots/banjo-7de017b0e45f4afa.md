---
title: Extract LSP param parsing helper
status: completed
priority: 2
issue-type: task
created-at: "\"2026-01-08T17:13:41.486065+02:00\""
---

Fixed: repeated param parsing in `src/lsp/server.zig:302`/`src/lsp/server.zig:607`/`src/lsp/server.zig:667`/`src/lsp/server.zig:833` now uses shared helpers at `src/lsp/server.zig:100` and `src/lsp/server.zig:119`.
