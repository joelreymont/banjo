---
title: Implement turn/interrupt for Codex cancel
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:44.305655+02:00\""
closed-at: "2026-01-11T12:38:35.719030+02:00"
---

Remove SIGINT from codex_bridge.zig:582. Add sendInterrupt() that sends turn/interrupt JSON-RPC with thread_id+turn_id (v2.rs:1522). Track current turn_id in bridge state. Handler calls bridge.sendInterrupt() on cancel.
