---
title: Remove auth_token from lockfile
status: closed
priority: 2
issue-type: task
created-at: "\"2026-01-16T17:16:25.144410+02:00\""
closed-at: "2026-01-16T18:00:09.564926+02:00"
---

src/nvim/lockfile.zig:7,28: Remove auth_token field from LockFile and LockFileData. Update create:31 to not require auth_token param
