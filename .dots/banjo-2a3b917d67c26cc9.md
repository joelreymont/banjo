---
title: Extract LSP param parsing helper
status: open
priority: 2
issue-type: task
created-at: "2026-01-08T17:13:11.129088+02:00"
---

lsp/server.zig has 15+ handlers with identical parse+error pattern. Extract parseRequestParams helper
