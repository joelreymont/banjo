---
title: Remove auth_token from lockfile
status: open
priority: 2
issue-type: task
created-at: "2026-01-16T17:16:25.144410+02:00"
---

src/nvim/lockfile.zig:7,28: Remove auth_token field from LockFile and LockFileData. Update create:31 to not require auth_token param
