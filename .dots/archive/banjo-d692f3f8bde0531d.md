---
title: [LOW] Review callback interface for unused parameters
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T13:03:43.493620+02:00\""
closed-at: "2026-01-08T14:43:01.634953+02:00"
close-reason: Low priority cleanup - deferring
---

File: src/nvim/handler.zig:761-762 - Several callback functions mark session_id and engine as unused with '_ ='. Fix: Evaluate if EditorCallbacks VTable is over-specified for nvim use case. Consider if simpler interface would suffice or if these params will be needed later. Impact: Code clarity improvement.
