---
title: Emacs link skip in code blocks
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-01-17T07:29:08.964923+02:00\\\"\""
closed-at: "2026-01-17T07:32:00.518542+02:00"
close-reason: completed
---

Full context: emacs/banjo.el:185-238, 240-255. Cause: link buttons applied inside fenced code blocks. Fix: mark code-block lines and skip link creation when banjo-code-block property present.
