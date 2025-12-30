# Claude Code Direct Communication

## Streaming JSON Mode

Bypass SDK, talk directly to Claude Code:

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
| `--replay-user-messages` | Echo user messages back on stdout (stream-json only) |
| `--dangerously-skip-permissions` | Bypass perms |
| `--permission-mode <mode>` | Set perm mode |
| `--allowedTools <tools>` | Whitelist tools |
| `--disallowedTools <tools>` | Blacklist tools |
| `-c, --continue` | Continue last session |
| `-r, --resume <id>` | Resume by session ID |
| `--fork-session` | Resume and create new session ID |
| `--no-session-persistence` | Disable session persistence (print mode only) |

## Stream JSON Input Format

When using `--input-format stream-json`, send messages as:

```json
{"type":"user","message":{"role":"user","content":"your prompt here"}}
```

**IMPORTANT**:
- Requires `--verbose` flag when using `-p` with `stream-json`
- `type` must be "user" or "control" at top level
- `message.role` must be "user"
- `message.content` is the prompt text

The CLI reference does not document image/audio payloads for stream-json input.
Our live tests with content blocks show:
- `image` blocks are accepted but can fail if the image cannot be processed.
- `audio` blocks are rejected (unsupported input tag).

Example command:
```bash
echo '{"type":"user","message":{"role":"user","content":"hello"}}' | \
  claude -p --verbose --input-format stream-json --output-format stream-json
```

## Stream JSON Output Format

Output stream contains JSON objects per line:

```json
{"type": "system", "subtype": "init", ...}
{"type": "system", "subtype": "hook_response", ...}
{"type": "assistant", "message": {"role":"assistant","content": [{"type":"text","text":"..."}]}}
{"type": "result", "subtype": "success", "result": "...", "duration_ms": 123}
```

### Output Message Types

| type | subtype | Description |
|------|---------|-------------|
| system | init | Session initialization with tools, model info |
| system | hook_response | Hook stdout/stderr from SessionStart etc |
| assistant | - | Model response with content blocks |
| result | success/error | Final result with stats |

## Tool Use Events in Stream

When Claude uses a tool, stream contains:
1. `content_block_start` with `tool_use` type
2. `content_block_delta` with input JSON
3. `content_block_stop`
4. Tool result from MCP server

## Hooks Architecture

### Claude Code Hooks (shell commands)
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

## Live Multimodal Tests (stream-json)

Image content block:
```
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Describe the image in one word."},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"...base64..."}}]}}
```
Result (Claude Code 2.0.76): error "Could not process image".

Audio content block:
```
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Transcribe the audio."},{"type":"audio","source":{"type":"base64","media_type":"audio/wav","data":"...base64..."}}]}}
```
Result: error "Input tag 'audio' ... does not match any of the expected tags".

## Sources

- [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Subprocess issue #771](https://github.com/anthropics/claude-code/issues/771)
- [Streaming output #733](https://github.com/anthropics/claude-code/issues/733)
