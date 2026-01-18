---
title: Restructure history/input layout
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T17:03:00.669077+02:00\""
closed-at: "2026-01-19T05:33:44.276279+02:00"
close-reason: completed
blocks:
  - banjo-define-neogit-layout-335eb23d
---

Full context: nvim/lua/banjo/panel.lua:600-720 (panel splits), 917-1100 (append/render), 172-206 (input buffer). Root cause: history and input are separate windows; neogit-style expects a single buffer with input below history. Fix: restructure panel to render History section above Input section (single buffer or fixed bottom region), keep prompt below history, manage scrolling. Why: traditional chat UX + neogit feel. Verification: panel_spec.lua asserts input region below history; e2e verifies typing sends prompt.
