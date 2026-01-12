---
title: Implement ReviewDecision for Codex approvals
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:59.156360+02:00\""
closed-at: "2026-01-11T12:43:11.625938+02:00"
---

Replace allow/decline/allow_always with Codex ReviewDecision: Approved, ApprovedExecpolicyAmendment, ApprovedForSession, Denied, Abort. Update respondApproval in codex_bridge.zig:884. See protocol.rs:1857
