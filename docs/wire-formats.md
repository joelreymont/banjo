# Wire Format Specifications

## ACP (Agent Client Protocol)

JSON-RPC 2.0 over stdio between Zed and agents.

### initialize Response

```json
{
  "jsonrpc": "2.0",
  "result": {
    "protocolVersion": 1,
    "agentInfo": {
      "name": "Banjo Duet",
      "title": "Banjo Duet",
      "version": "0.5.0 (hash)"
    },
    "agentCapabilities": {
      "promptCapabilities": {
        "image": true,
        "audio": false,
        "embeddedContext": true
      },
      "mcpCapabilities": {
        "http": false,
        "sse": false
      },
      "sessionCapabilities": {},
      "loadSession": false
    },
    "authMethods": [
      {
        "id": "claude-login",
        "name": "Log in with Claude Code",
        "description": "Run `claude /login` in the terminal"
      }
    ]
  },
  "id": 1
}
```

### session/update Notification

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "string",
    "update": { /* SessionUpdate union */ }
  }
}
```

### SessionUpdate Union Types

The `update` field uses a `sessionUpdate` discriminator:

#### agent_message_chunk
```json
{
  "sessionUpdate": "agent_message_chunk",
  "content": {
    "type": "text",
    "text": "Hello! How can I help?"
  }
}
```

#### user_message_chunk
```json
{
  "sessionUpdate": "user_message_chunk",
  "content": {
    "type": "text",
    "text": "User message..."
  }
}
```

#### agent_thought_chunk
```json
{
  "sessionUpdate": "agent_thought_chunk",
  "content": {
    "type": "text",
    "text": "Thinking about..."
  }
}
```

#### tool_call
```json
{
  "sessionUpdate": "tool_call",
  "toolCallId": "uuid",
  "title": "Read",
  "kind": "read",
  "status": "pending",
  "rawInput": { "file_path": "/path/to/file" }
}
```

#### tool_call_update
```json
{
  "sessionUpdate": "tool_call_update",
  "toolCallId": "uuid",
  "status": "completed",
  "title": "Read",
  "content": [
    { "type": "content", "content": { "type": "text", "text": "file contents..." } }
  ]
}
```

Tool call content entries may also include `terminalId` (terminal output) or `path`/`oldText`/`newText` (file edits).

#### plan
```json
{
  "sessionUpdate": "plan",
  "entries": [
    {
      "id": "1",
      "content": "Step description",
      "status": "pending"
    }
  ]
}
```

#### available_commands_update
```json
{
  "sessionUpdate": "available_commands_update",
  "availableCommands": [
    { "name": "commit", "description": "Commit changes" }
  ]
}
```

#### current_mode_update
```json
{
  "sessionUpdate": "current_mode_update",
  "currentModeId": "plan"
}
```

### session/new Response

```json
{
  "jsonrpc": "2.0",
  "result": {
    "sessionId": "string",
    "configOptions": [
      {
        "id": "auto_resume",
        "name": "Auto-resume sessions",
        "description": "Resume the last session on startup",
        "type": "select",
        "currentValue": "true",
        "options": [
          { "value": "true", "name": "On" },
          { "value": "false", "name": "Off" }
        ]
      }
    ],
    "models": {
      "availableModels": [
        { "id": "sonnet", "name": "Claude Sonnet", "description": "Fast, balanced" }
      ],
      "currentModelId": "sonnet"
    },
    "modes": {
      "availableModes": [
        { "id": "default", "name": "Default", "description": "Ask before executing tools" }
      ],
      "currentModeId": "default"
    }
  },
  "id": 1
}
```

Note: ACP config options use `type: "select"` with `currentValue` and `options` value IDs.

### ContentChunk Types

```json
{ "type": "text", "text": "..." }
{ "type": "image", "data": "base64...", "mimeType": "image/png" }
{ "type": "audio", "data": "base64...", "mimeType": "audio/wav" }
{ "type": "resource", "resource": { "uri": "file:///path/to/file", "text": "..." } }
{ "type": "resource_link", "uri": "file:///path/to/file", "name": "file.zig" }
```

### ToolCallStatus

- `pending` - Tool call initiated
- `in_progress` - Execution in progress
- `completed` - Finished successfully
- `failed` - Execution failed

### ToolCallKind

- `read` - File read
- `edit` - File edit
- `write` - File write
- `delete` - File delete
- `move` - File move
- `search` - Search
- `execute` - Terminal command
- `think` - Internal reasoning
- `fetch` - Network fetch
- `switch_mode` - Mode change
- `other` - Other tool types

### PromptResponse

Response to `session/prompt`:

```json
{
  "stopReason": "end_turn"
}
```

| stopReason | Description |
|------------|-------------|
| `end_turn` | Normal completion |
| `cancelled` | User cancelled |
| `max_tokens` | Token limit reached |
| `max_turn_requests` | Hit max budget/turns |
| `refusal` | Model refused |

### CLI → ACP Stop Reason Mapping

| CLI subtype | ACP stopReason |
|-------------|----------------|
| `success` | `end_turn` |
| `cancelled` | `cancelled` |
| `max_tokens` | `max_tokens` |
| `error_max_turns` | `max_turn_requests` |
| `error_max_budget_usd` | `max_turn_requests` |

Banjo treats `error_max_turns` as a continue signal and will auto-send
`continue` when Dots reports pending tasks (`dot ls --json`).

## Claude Code Stream JSON

Communication between banjo and Claude Code.

### Input Format

```json
{"type":"user","message":{"role":"user","content":"prompt text"}}
```

Fields:
- `type`: `"user"` or `"control"`
- `message.role`: Must be `"user"`
- `message.content`: The prompt text

### Output Format

Newline-delimited JSON objects:

#### system/init
```json
{
  "type": "system",
  "subtype": "init",
  "session_id": "uuid",
  "tools": ["Read", "Edit", "Bash", ...],
  "model": "claude-opus-4-5-20251101"
}
```

#### system/auth_required
```json
{
  "type": "system",
  "subtype": "auth_required",
  "content": "Please run /login to authenticate"
}
```

#### system/hook_response
```json
{
  "type": "system",
  "subtype": "hook_response",
  "hook_name": "SessionStart:startup",
  "stdout": "...",
  "stderr": "",
  "exit_code": 0
}
```

#### assistant
```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      { "type": "text", "text": "Hello!" },
      { "type": "tool_use", "id": "...", "name": "Read", "input": {...} }
    ]
  },
  "session_id": "uuid"
}
```

#### assistant (tool_result content block)
```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "tool_1",
        "content": [
          { "type": "text", "text": "file contents..." }
        ],
        "is_error": false
      }
    ]
  }
}
```

#### user (tool_result content block)
```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "tool_1",
        "content": "error output",
        "is_error": true
      }
    ]
  }
}
```

#### result
```json
{
  "type": "result",
  "subtype": "success",
  "result": "Final response text",
  "duration_ms": 1234,
  "session_id": "uuid"
}
```

#### stream_event (message_start/stop)
```json
{
  "type": "stream_event",
  "event": { "type": "message_start" }
}
```

```json
{
  "type": "stream_event",
  "event": { "type": "message_stop" }
}
```

#### stream_event (content_block_delta)
```json
{
  "type": "stream_event",
  "event": {
    "type": "content_block_delta",
    "delta": { "type": "text_delta", "text": "Hello" }
  }
}
```

```json
{
  "type": "stream_event",
  "event": {
    "type": "content_block_delta",
    "delta": { "type": "thinking_delta", "thinking": "..." }
  }
}
```

### CLI Flags

Required for stream-json mode:
```bash
claude -p --verbose \
  --input-format stream-json \
  --output-format stream-json
```

## Codex App Server (JSON-RPC JSONL)

Communication between banjo and `codex app-server`.

### Input Format

Codex app-server speaks JSON-RPC over JSONL (one JSON object per line):

```bash
codex app-server
```

Initialize the session, then send an `initialized` notification:

```json
{ "id": 1, "method": "initialize", "params": { "clientInfo": { "name": "banjo", "title": "Banjo ACP Agent", "version": "0.5.0" } } }
{ "method": "initialized" }
```

Start a thread, then start a turn with user input:

```json
{ "id": 2, "method": "thread/start", "params": { "model": null, "cwd": "/path/to/repo", "approvalPolicy": "never", "experimentalRawEvents": false } }
{ "id": 3, "method": "turn/start", "params": { "threadId": "thr_123", "input": [ { "type": "text", "text": "Say hello" } ], "approvalPolicy": "never" } }
```

### Output Format

JSON-RPC responses and notifications. Key notifications:

#### thread/started
```json
{ "method": "thread/started", "params": { "thread": { "id": "thr_123" } } }
```

#### turn/started
```json
{ "method": "turn/started", "params": { "threadId": "thr_123", "turn": { "id": "turn_1", "status": "inProgress", "items": [], "error": null } } }
```

#### item/agentMessage/delta
```json
{ "method": "item/agentMessage/delta", "params": { "threadId": "thr_123", "turnId": "turn_1", "itemId": "item_1", "delta": "Hello" } }
```

#### item/started (command execution begins)
```json
{
  "method": "item/started",
  "params": {
    "threadId": "thr_123",
    "turnId": "turn_1",
    "item": { "type": "commandExecution", "id": "item_2", "command": "/bin/zsh -lc ls", "cwd": "/path/to/repo", "processId": null, "status": "inProgress", "commandActions": [], "aggregatedOutput": null, "exitCode": null, "durationMs": null }
  }
}
```

#### item/completed (command execution ends)
```json
{
  "method": "item/completed",
  "params": {
    "threadId": "thr_123",
    "turnId": "turn_1",
    "item": { "type": "commandExecution", "id": "item_2", "command": "/bin/zsh -lc ls", "cwd": "/path/to/repo", "processId": null, "status": "completed", "commandActions": [], "aggregatedOutput": "file1\nfile2\n", "exitCode": 0, "durationMs": 12 }
  }
}
```

#### turn/completed
```json
{ "method": "turn/completed", "params": { "threadId": "thr_123", "turn": { "id": "turn_1", "status": "completed", "items": [], "error": null } } }
```

### Ordering and approvals

Ordering (v2):
- `turn/start` sends a JSON-RPC response first, then emits `turn/started`.
- Item notifications (`item/*`, deltas) stream after `turn/started`.

Approval requests (v2):
- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`

Respond with a JSON-RPC response whose `result` is:

```json
{ "decision": "accept" }
```

Allowed decisions: `accept`, `acceptForSession`, `acceptWithExecpolicyAmendment`, `decline`, `cancel`.

Legacy approvals (v1) use `applyPatchApproval` and `execCommandApproval` and expect a `decision`
value from `ReviewDecision` (snake_case), e.g. `approved`, `approved_for_session`,
`approved_execpolicy_amendment`, `denied`, `abort`.

Notes:
- JSON-RPC responses echo the request `id` and return a `result` object.
- Codex app-server omits the `"jsonrpc":"2.0"` header.
- Item types are camelCase (e.g., `agentMessage`, `commandExecution`).
- `exit_code` is null until completion

## ACP Implementation Status

### Implemented Methods

| Method | Status | Notes |
|--------|--------|-------|
| initialize | ✅ | Full capability negotiation |
| session/new | ✅ | With modes, models, config |
| session/prompt | ✅ | Streaming via Claude/Codex bridges |
| session/cancel | ✅ | Notification handler |
| session/set_mode | ✅ | Mode switching |
| session/set_model | ✅ | Model switching |
| session/request_permission | ✅ | With Always Allow persistence |
| fs/read_text_file | ✅ | Client capability |
| fs/write_text_file | ✅ | Client capability |
| terminal/create | ✅ | For output mirroring |
| terminal/output | ✅ | Get terminal output |
| terminal/wait_for_exit | ✅ | Wait for completion |
| terminal/release | ⚠️ | Skipped to keep terminals visible |
| session/load | ❌ | loadSession=false |
| terminal/kill | ❌ | Not implemented |

### Session Update Types

| Update Type | Status | Notes |
|-------------|--------|-------|
| agent_message_chunk | ✅ | Streaming text |
| user_message_chunk | ✅ | For nudge prompts |
| agent_thought_chunk | ✅ | Extended thinking |
| tool_call | ✅ | With locations for follow-agent |
| tool_call_update | ⚠️ | Missing rawOutput, edit diffs |
| plan | ✅ | For todo/plan entries |
| available_commands_update | ✅ | Slash commands |
| current_mode_update | ✅ | Mode changes |
| current_model_update | ✅ | Model changes |

### Known Gaps

1. **tool_call_update.rawOutput**: Not sending full JSON tool result
2. **Edit diff content**: Should send `path`/`oldText`/`newText` for edits
3. **locations.line**: Only sending path, not line numbers
4. **terminalId in content**: Terminal output not linked to tool calls

## Sources

- [ACP Schema](https://agentclientprotocol.com/protocol/schema)
- [ACP TypeScript SDK](https://github.com/agentclientprotocol/typescript-sdk)
- [Zed claude-code-acp](https://github.com/zed-industries/claude-code-acp)
