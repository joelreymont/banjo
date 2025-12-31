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
- `type` must be "user" at top level (control is rejected in stream-json input as of 2.0.76)
- `message.role` must be "user"
- `message.content` is the prompt text
- Live tests show Claude Code rejects `type:"control"` inputs (error: "Expected message type 'user' or 'control', got 'control'").

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

### Turn Limits and Continue

Claude Code signals max-turn limits with a `result` message:

```json
{ "type": "result", "subtype": "error_max_turns", "is_error": false }
```

Banjo detects this and will auto-send `continue` when Dots reports pending tasks
via `dot ls --json`. If Dots is not installed or returns no tasks, Banjo ends
the prompt with `max_turn_requests`.

## Tool Use Events in Stream

When Claude uses a tool, stream contains:
1. `content_block_start` with `tool_use` type
2. `content_block_delta` with input JSON
3. `content_block_stop`
4. Tool result from MCP server

## Hooks Architecture

### Hook Events

Claude Code provides 8 hook lifecycle events:

| Event | When | Can Block |
|-------|------|-----------|
| `SessionStart` | Session begins | No |
| `UserPromptSubmit` | User submits prompt | No |
| `PreToolUse` | Before tool execution | Yes |
| `PermissionRequest` | Permission dialog shown | Yes |
| `PostToolUse` | After tool completes | No |
| `Notification` | Notifications sent | No |
| `Stop` | Claude stops | No |
| `SubagentStop` | Subagent stops | No |

### Hook Input (stdin)

All hooks receive JSON via stdin:

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/working/directory",
  "permission_mode": "default",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": { "command": "npm run build" },
  "tool_use_id": "toolu_01ABC123"
}
```

### Hook Output (stdout)

Return JSON to control behavior:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedInput": { "command": "npm run build --quiet" }
    }
  }
}
```

Decision behaviors:
- `allow` - Approve without prompting (optionally modify input with `updatedInput`)
- `deny` - Block with optional `message` and `interrupt: true` to stop Claude
- `ask` - Show permission dialog to user

### Exit Codes

- `0` - Success, parse stdout JSON for decision
- `2` - Blocking error, stderr shown to user
- Other - Non-blocking error, stderr shown in verbose mode

### Configuration

Hooks are defined in `~/.claude/settings.json` or `.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "/path/to/script.sh" }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "/path/to/validate.py" }]
      }
    ]
  }
}
```

Matchers: `Bash`, `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Task`, `WebFetch`, `WebSearch`, `*` (all)

### Environment Variables

- `CLAUDE_PROJECT_DIR` - Absolute path to project root
- `CLAUDE_CODE_REMOTE` - "true" if running in web environment
- `CLAUDE_ENV_FILE` - Only available in SessionStart

### Banjo Permission Hook

Banjo uses a PermissionRequest hook to forward tool approvals to Zed via ACP:

1. Banjo creates Unix socket at `/tmp/banjo-{session}.sock`
2. Hook connects and sends tool details
3. Banjo forwards to Zed via `session/request_permission`
4. User approves/denies in Zed UI
5. Banjo sends response to hook
6. Hook returns decision to Claude Code

This enables interactive permission control even in stream-json mode.

**Settings File Hierarchy (highest to lowest precedence):**

| Scope | Location | Shared? |
|-------|----------|---------|
| Local | `.claude/settings.local.json` | No |
| Project | `.claude/settings.json` | Yes |
| User | `~/.claude/settings.json` | No |

**Setup:**

Add to `~/.claude/settings.json` (or project-level for dev builds):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [{ "type": "command", "command": "banjo hook permission" }]
      }
    ]
  }
}
```

For dev builds, use the full path: `/path/to/banjo/zig-out/bin/banjo hook permission`

The hook reads PreToolUse JSON from stdin, forwards to Banjo via Unix socket, and outputs the decision.

## Known Issues

- Node.js subprocess spawning has bugs (use Python or direct exec)
- `--verbose` requires `--json` in print mode
- Stream-json does not accept control messages for in-session permission mode changes; use `--permission-mode` at process start and restart to apply changes.

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
