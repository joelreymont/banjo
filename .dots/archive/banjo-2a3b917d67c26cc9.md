---
title: Extract LSP param parsing helper
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T17:13:11.129088+02:00\""
closed-at: "2026-01-08T19:35:12.988255+02:00"
close-reason: duplicate
---

lsp/server.zig has 15+ handlers with identical parse+error pattern. Extract parseRequestParams helper
