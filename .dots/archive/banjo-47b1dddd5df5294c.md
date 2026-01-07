---
title: "Switch to plenary: Update validation script"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T07:58:37.319681+02:00"
closed-at: "2026-01-06T08:02:28.133918+02:00"
---

File: nvim/scripts/validate.sh - Update to run plenary tests instead of custom runner. Change nvim -l scripts/run_tests.lua to use plenary.test_harness. Ensure syntax validation still runs first.
