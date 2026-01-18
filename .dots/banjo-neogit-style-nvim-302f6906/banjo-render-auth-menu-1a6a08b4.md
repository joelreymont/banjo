---
title: Render auth menu header
status: closed
priority: 1
issue-type: task
created-at: "\"2026-01-18T17:02:42.562775+02:00\""
closed-at: "2026-01-18T21:38:18.981689+02:00"
close-reason: completed
blocks:
  - banjo-define-neogit-layout-335eb23d
---

Full context: nvim/lua/banjo/panel.lua:1323-1388 (winbar status), 32-49 (highlights). Root cause: auth/permission mode not visible inline; winbar shows mode but no menu. Fix: render top-of-buffer header with inline auth options (default/accept_edits/auto_approve/plan_only), engine/model/connection; use extmarks/virtual text + highlights. Why: neogit-style discoverability. Verification: unit test for header lines + mode highlighting.
