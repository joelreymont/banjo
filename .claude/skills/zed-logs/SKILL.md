---
name: zed-logs
description: Check Zed editor logs for banjo/agent errors. Use when user says "check zed logs", "zed errors", or "what's the zed error".
---

# Zed Logs

Check Zed editor logs for ACP agent issues.

## Commands

```bash
# Recent agent logs (banjo + errors)
tail -100 ~/Library/Logs/Zed/Zed.log | grep -i -E "(banjo|agent|error)" | tail -30

# All recent logs
tail -50 ~/Library/Logs/Zed/Zed.log

# Follow logs live
tail -f ~/Library/Logs/Zed/Zed.log | grep -i agent

# Clear and watch
: > ~/Library/Logs/Zed/Zed.log && tail -f ~/Library/Logs/Zed/Zed.log
```

## Log Patterns

- `agent stderr:` - Output from agent process (banjo logs here)
- `agent_servers::acp` - ACP connection handling
- `error(...)` - Error from agent
- `info(banjo)` - Banjo startup
- `debug(agent)` - Request handling

## Common Issues

| Error | Cause | Fix |
|-------|-------|-----|
| `UnknownField` | Missing field in param struct | Add field or `ignore_unknown_fields = true` |
| `not registered` | Config key mismatch | Check `agent_servers` key in Zed settings |
| No output | Agent crashed on startup | Run `./zig-out/bin/banjo` manually to see error |

## Zed Config Location

`~/.config/zed/settings.json` → `agent_servers`
