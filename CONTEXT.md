# Session Context - Banjo ACP Agent

## Current Task
**`bd` CLI in Zig** - fast beads issue tracker for Claude hooks. **COMPLETE**

## Status

Built and installed `/Users/joel/Work/bd` - a Zig implementation of essential `bd` commands:
- `bd init [--stealth]` - create .beads directory
- `bd list --json [--status S]` - list/filter issues
- `bd ready --json` - list ready issues (open, no blocking deps)
- `bd create <title> -p <priority> -d <desc> --json` - create issue
- `bd update <id> [-d desc] [--status S]` - update issue
- `bd close <id> --reason R` - close issue

Installed to: `~/bin/bd`
Source: `/Users/joel/Work/zig-beads/`
Beads reference: `/Users/joel/Work/beads/`

### What Works
- Reads/writes beads JSONL format directly
- Preserves all fields when updating (doesn't lose data)
- Dependency checking for `ready` command
- RFC3339 timestamps with microseconds (`2025-12-24T19:20:50.123456Z`)
- Compatible with bd-load.py and bd-sync.py hooks

### Not Implemented (not needed by hooks)
- `bd show` - display single issue
- `bd deps` - dependency management
- `bd config` - configuration
- Daemon mode (direct JSONL access is fast enough)

## Banjo Status
Core ACP implementation complete. Tool proxy placeholder added.

## Files
- `/Users/joel/Work/bd/src/main.zig` - main implementation
- `/Users/joel/Work/bd/build.zig` - Zig 0.15 build config
- `~/.claude/scripts/bd-load.py` - SessionStart hook
- `~/.claude/scripts/bd-sync.py` - PostToolUse[TodoWrite] hook
