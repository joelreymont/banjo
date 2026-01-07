---
title: "Switch to plenary: Update helpers.lua for plenary compat"
status: closed
priority: 2
issue-type: task
created-at: "2026-01-06T07:58:35.784564+02:00"
closed-at: "2026-01-06T08:02:28.126228+02:00"
---

File: nvim/tests/helpers.lua - Remove custom describe/it/run_tests implementation (lines 161-196). Keep utility functions (wait_for, setup_test_env, assertions). Plenary provides describe/it/before_each/after_each natively.
