# Claude Code CLI Direct Communication

## Streaming JSON Mode

Bypass SDK, talk directly to CLI:

```bash
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --include-partial-messages \
  "your prompt"
```

## Key Flags

| Flag | Description |
|------|-------------|
| `-p, --print` | Non-interactive mode |
| `--output-format stream-json` | JSON stream output |
| `--input-format stream-json` | JSON stream input |
| `--include-partial-messages` | Partial chunks |
| `--dangerously-skip-permissions` | Bypass perms |
| `--permission-mode <mode>` | Set perm mode |
| `--allowedTools <tools>` | Whitelist tools |
| `--disallowedTools <tools>` | Blacklist tools |
| `--mcp-config <json>` | MCP servers |
| `-c, --continue` | Continue last session |
| `-r, --resume <id>` | Resume by session ID |

## Stream JSON Message Types

Output stream contains JSON objects per line:

```json
{"type": "system", "subtype": "init", ...}
{"type": "assistant", "message": {"content": [...]}}
{"type": "stream_event", ...}
{"type": "result", "subtype": "success"}
```

## Tool Use Events in Stream

When Claude uses a tool, stream contains:
1. `content_block_start` with `tool_use` type
2. `content_block_delta` with input JSON
3. `content_block_stop`
4. Tool result from MCP server

## Hooks Architecture

### CLI Hooks (shell commands)
Defined in `.claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": ["./scripts/check-tool.sh"],
    "PostToolUse": ["./scripts/log-tool.sh"]
  }
}
```
These run INSIDE Claude Code process.

### SDK Hooks (JS callbacks)
The TS implementation uses `@anthropic-ai/claude-agent-sdk` which provides JS callback hooks. These run in the ACP adapter process, NOT in Claude Code.

### Zig Implementation Strategy
Without the SDK, we implement "hooks" by:
1. Parsing stream-json output
2. Detecting tool_use events
3. Intercepting before forwarding to Zed
4. Can allow/deny/modify based on settings

This is equivalent functionality but at the ACP layer.

## Known Issues

- Node.js subprocess spawning has bugs (use Python or direct exec)
- `--verbose` requires `--json` in print mode

## Sources

- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Subprocess issue #771](https://github.com/anthropics/claude-code/issues/771)
- [Streaming output #733](https://github.com/anthropics/claude-code/issues/733)
