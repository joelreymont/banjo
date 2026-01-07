---
title: "Switch to plenary: Rewrite test runner for plenary"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T07:58:36.168972+02:00"
closed-at: "2026-01-06T08:02:28.130100+02:00"
---

File: nvim/scripts/run_tests.lua - Replace custom test runner with plenary test harness. Use require('plenary.test_harness').test_directory(). Remove manual describe/it globals setup (lines 9-21). Plenary handles this.
