---
title: Update Nvim panel tests
status: open
priority: 1
issue-type: task
created-at: "2026-01-18T17:03:17.297745+02:00"
blocks:
  - banjo-restructure-history-input-b5e3d9bc
---

Full context: nvim/tests/panel_spec.lua:1-200, nvim/tests/panel_e2e_spec.lua:1-200. Root cause: tests assume split windows + no header menu. Fix: update/extend tests for header/auth menu, input below history, action row, keymaps. Why: prevent regressions. Verification: nvim test suite passes.
