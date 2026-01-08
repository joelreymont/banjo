---
title: Fix model validation to use StaticStringMap
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-08T14:57:02.565655+02:00\""
closed-at: "2026-01-08T14:59:51.971772+02:00"
close-reason: Fixed - converted to StaticStringMap per CLAUDE.md rules
---

File: handler.zig:711-718 - Uses array iteration with mem.eql instead of StaticStringMap per CLAUDE.md rules
