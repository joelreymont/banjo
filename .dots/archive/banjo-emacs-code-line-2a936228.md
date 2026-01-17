---
title: Emacs code-line buffer cap
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-17T07:29:14.722119+02:00\""
closed-at: "2026-01-17T07:32:05.004150+02:00"
close-reason: completed
---

Full context: emacs/banjo.el:258-268. Cause: banjo--code-line-buffer grows unbounded if no newline. Fix: cap buffer size and truncate safely while preserving fence detection.
