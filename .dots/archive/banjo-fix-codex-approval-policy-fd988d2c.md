---
title: Fix Codex approval_policy mapping
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-11T12:31:44.103733+02:00\""
closed-at: "2026-01-11T12:56:09.324134+02:00"
---

src/core/permission_mode.zig:42 emits auto-edit/full-auto but Codex only accepts untrusted/on-failure/on-request/never. Map: default->on-request, acceptEdits->untrusted, bypassPermissions/dontAsk->never. See /tmp/codex/codex-rs/protocol/src/protocol.rs:257
