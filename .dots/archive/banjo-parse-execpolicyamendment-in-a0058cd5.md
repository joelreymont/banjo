---
title: Parse ExecPolicyAmendment in approval requests
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:59.360338+02:00\""
closed-at: "2026-01-11T12:43:55.473073+02:00"
---

Codex sends proposed_execpolicy_amendment in ExecApprovalRequestEvent (approvals.rs:12). Parse this in codex_bridge.zig approval handling. Pass to UI for ApprovedExecpolicyAmendment decision.
