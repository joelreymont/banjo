# Wire Format Specifications

## ACP (Agent Client Protocol)

JSON-RPC 2.0 over stdio between Zed and agents.

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
  "content": [{ "type": "text", "text": "file contents..." }]
}
```

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

### ContentChunk Types

```json
{ "type": "text", "text": "..." }
{ "type": "image", "data": "base64...", "mediaType": "image/png" }
```

### ToolCallStatus

- `pending` - Tool call initiated
- `in_progress` - Execution in progress
- `completed` - Finished successfully
- `failed` - Execution failed

### ToolCallKind

- `read` - File read
- `write` - File write
- `edit` - File edit
- `command` - Terminal command
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
| `max_turn_requests` | Hit max budget/turns |

### CLI → ACP Stop Reason Mapping

| CLI subtype | ACP stopReason |
|-------------|----------------|
| `success` | `end_turn` |
| `cancelled` | `cancelled` |
| `max_tokens` | `max_tokens` |
| `error_max_turns` | `max_turn_requests` |
| `error_max_budget_usd` | `max_turn_requests` |

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

## Codex JSONL

Communication between banjo and `codex exec --json`.

### Input Format

Codex takes raw prompt text (not JSON) on stdin:

```bash
codex exec --json -
```

Optional resume:

```bash
codex exec --json resume <thread_id> -
```

### Output Format

Newline-delimited JSON objects with a `type` field:

#### thread.started
```json
{ "type": "thread.started", "thread_id": "uuid" }
```

#### turn.started
```json
{ "type": "turn.started" }
```

#### item.started (tool execution begins)
```json
{
  "type": "item.started",
  "item": {
    "id": "item_1",
    "type": "command_execution",
    "command": "/bin/zsh -lc ls",
    "aggregated_output": "",
    "exit_code": null,
    "status": "in_progress"
  }
}
```

#### item.completed (reasoning)
```json
{
  "type": "item.completed",
  "item": {
    "id": "item_0",
    "type": "reasoning",
    "text": "**Listing files**"
  }
}
```

#### item.completed (agent message)
```json
{
  "type": "item.completed",
  "item": {
    "id": "item_2",
    "type": "agent_message",
    "text": "Hello"
  }
}
```

#### item.completed (tool execution ends)
```json
{
  "type": "item.completed",
  "item": {
    "id": "item_1",
    "type": "command_execution",
    "command": "/bin/zsh -lc ls",
    "aggregated_output": "file1\nfile2\n",
    "exit_code": 0,
    "status": "completed"
  }
}
```

#### turn.completed
```json
{
  "type": "turn.completed",
  "usage": {
    "input_tokens": 123,
    "cached_input_tokens": 0,
    "output_tokens": 45
  }
}
```

Notes:
- `item.type` values observed: `reasoning`, `agent_message`, `command_execution`
- `aggregated_output` may be empty on `item.started`
- `exit_code` is null until completion

## Sources

- [ACP Schema](https://agentclientprotocol.com/protocol/schema)
- [ACP TypeScript SDK](https://github.com/agentclientprotocol/typescript-sdk)
- [Zed claude-code-acp](https://github.com/zed-industries/claude-code-acp)
