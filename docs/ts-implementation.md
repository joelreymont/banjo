# TypeScript Implementation Analysis

Source: `/Users/joel/Work/claude-code-acp`

## Architecture

```
Zed (ACP Client)
    ↓ JSON-RPC over stdio
claude-code-acp (Node.js)
    ↓ Claude Agent SDK
Claude Code (subprocess)
    ↓ API calls
Anthropic API
```

## Core Files

| File | LOC | Purpose |
|------|-----|---------|
| `acp-agent.ts` | 839 | Main agent, session mgmt |
| `tools.ts` | 697 | Tool conversion, hooks |
| `settings.ts` | 523 | Permission management |
| `utils.ts` | 172 | Streams, helpers |
| `lib.ts` | - | Public exports |
| `index.ts` | - | Entry point |

## Session Structure

```typescript
type Session = {
  query: Query;           // SDK query stream
  input: Pushable<Msg>;   // Input queue
  cancelled: boolean;
  permissionMode: PermissionMode;
  settingsManager: SettingsManager;
};
```

## Key Classes

### ClaudeAcpAgent
- `initialize(req)` - Handshake
- `newSession(params)` - Create session
- `prompt(params)` - Main message loop
- `cancel(params)` - Cancel operation
- `canUseTool(sessionId)` - Permission callback

### SettingsManager
Multi-source settings with file watching:
1. `~/.claude/settings.json` (user)
2. `<cwd>/.claude/settings.json` (project)
3. `<cwd>/.claude/settings.local.json` (local)
4. Platform managed-settings.json (enterprise)

Permission rules:
- `"Read"` - Any Read
- `"Read(./.env)"` - Specific file
- `"Bash(npm run:*)"` - Prefix match

### Pushable<T>
Async queue bridging push-based input to async iteration.

## Hook Implementation

The "hooks" are **NOT** Claude Code hooks. They're SDK-level JS callbacks:

```typescript
hooks: {
  PreToolUse: [{
    hooks: [createPreToolUseHook(settingsManager)]
  }],
  PostToolUse: [{
    hooks: [createPostToolUseHook(logger)]
  }]
}
```

These intercept events from the SDK, not the CLI.

### createPreToolUseHook
1. Receives tool use event from SDK
2. Checks `settingsManager.checkPermission()`
3. Returns allow/deny/ask decision

### createPostToolUseHook
1. Receives tool result from SDK
2. Calls registered callbacks
3. Forwards to ACP client as `tool_call_update`

## Message Flow

1. ACP PromptRequest arrives
2. Convert via `promptToClaude()`
3. Push to session input queue
4. Iterate SDK query results:
   - `stream_event` → `streamEventToAcpNotifications()`
   - `assistant/user` → `toAcpNotifications()`
   - `result` → return stopReason
5. Send `sessionUpdate` notifications to Zed

## Tool Handling

Tools registered via MCP server:
- Read, Write, Edit (file ops)
- Bash, BashOutput, KillShell (terminal)

When client has capability (e.g., `fs/read_text_file`), tool delegates to client instead of local fs.

## What's NOT Supported

1. **Message editing** - Protocol doesn't support
2. **CLI hooks** - Uses SDK callbacks instead
3. **Queue without interrupt** - New prompt waits for current to complete
