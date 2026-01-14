Create or update a global skill called "dot" for task tracking. Trigger phrases: "dots", "tasks", "what's next", "add task", "new task", "show tasks", "complete task", "finish task", "start task", "remove task", "find task". The skill:

---
name: dot
description: Task tracking with dots CLI. Triggers: dots, tasks, what's next, add/show/complete/start/remove/find task
---

# Dots Task Tracking

## Commands

dot "title"                  # Quick add
dot add "title" -d "desc"    # Add with description
dot add "title" -p 1         # Add with priority (1=high)
dot add "title" -P parent-id # Add as child of parent
dot add "title" -a other-id  # Add dependency (after other)
dot ls                       # List all (> = active, o = open)
dot ls --status open         # Filter by status
dot ready                    # Show unblocked tasks only
dot show <id>                # Show details
dot on <id>                  # Start working
dot off <id> -r "reason"     # Complete with reason
dot rm <id>                  # Remove
dot tree                     # Show hierarchy
dot find "query"             # Search

## Workflow

1. `dot ls` or `dot ready` to see tasks
2. `dot on <id>` to start
3. Do the work
4. `dot off <id> -r "done"` when complete

## Task Descriptions (Required Format)

Use this structure in descriptions (-d flag):

file: <path>:<line>        # Primary file location
cause: <root cause>        # Why this needs to be done
fix: <approach>            # How to fix/implement
plan: <path>               # Optional: plan file path
deps: <dot-id>, ...        # Optional: dependent dots

Example:
dot add "Fix auth timeout" -d "file: src/auth.zig:142 | cause: token refresh race | fix: add mutex"

## On Session Start

1. Read project guidelines: AGENTS.md (global ~/.agents/ + project ./)
2. Read instructions: CLAUDE.md (global ~/.claude/ + project ./)
3. Check active dots: `dot ls --status active`
4. If plan file in dot description, read it
5. Continue with current task
