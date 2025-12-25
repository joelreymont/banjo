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

## Claude CLI Stream JSON

Communication between banjo and Claude Code CLI.

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

### CLI Flags

Required for stream-json mode:
```bash
claude -p --verbose \
  --input-format stream-json \
  --output-format stream-json
```

## Sources

- [ACP Schema](https://agentclientprotocol.com/protocol/schema)
- [ACP TypeScript SDK](https://github.com/agentclientprotocol/typescript-sdk)
- [Zed claude-code-acp](https://github.com/zed-industries/claude-code-acp)
