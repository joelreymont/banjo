# Agent Client Protocol (ACP) Specification

Reference: https://agentclientprotocol.com / https://github.com/zed-industries/agent-client-protocol

ACP is a JSON-RPC 2.0 protocol over stdio for communication between code editors (clients) and AI coding agents.

## Message Flow

```
Client                          Agent
   |                              |
   |--- initialize -------------->|
   |<-- InitializeResponse -------|
   |                              |
   |--- session/new ------------->|
   |<-- NewSessionResponse -------|
   |                              |
   |--- session/prompt ---------->|
   |<-- session/update (notif) ---|  (streaming updates)
   |<-- session/update (notif) ---|
   |<-- PromptResponse -----------|
   |                              |
   |--- session/cancel (notif) -->|  (optional)
```

## Methods

### Initialization
| Method | Dir | Description |
|--------|-----|-------------|
| `initialize` | C→A | Handshake, negotiate capabilities |
| `authenticate` | C→A | Auth using specified method |

### Session
| Method | Type | Description |
|--------|------|-------------|
| `session/new` | Req | Create session |
| `session/prompt` | Req | Send user prompt |
| `session/cancel` | Notif | Cancel current op |
| `session/update` | Notif | Stream progress (A→C) |
| `session/request_permission` | Req | Request tool permission |
| `session/set_mode` | Req | Set permission mode |
| `unstable_resumeSession` | Req | Resume existing session |

### File System (Agent→Client)
| Method | Description |
|--------|-------------|
| `fs/read_text_file` | Read file |
| `fs/write_text_file` | Write file |

### Terminal (Agent→Client)
| Method | Description |
|--------|-------------|
| `terminal/create` | Execute command |
| `terminal/output` | Get output |
| `terminal/wait_for_exit` | Wait completion |
| `terminal/kill` | Terminate |
| `terminal/release` | Release resources |

## Request/Response Schemas

### initialize

**Request (InitializeRequest):**
```zig
const InitializeRequest = struct {
    protocolVersion: i32,                    // Required: protocol version (currently 1)
    clientInfo: ClientInfo,
    clientCapabilities: ClientCapabilities,
};

const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

const ClientCapabilities = struct {
    fs: ?FsCapabilities = null,
    terminal: ?bool = null,
};

const FsCapabilities = struct {
    readTextFile: ?bool = null,
    writeTextFile: ?bool = null,
};
```

**Response (InitializeResponse):**
```zig
const InitializeResponse = struct {
    protocolVersion: i32,
    agentInfo: AgentInfo,
    agentCapabilities: AgentCapabilities,
    authMethods: []const AuthMethod,
};

const AgentCapabilities = struct {
    promptCapabilities: PromptCapabilities,
    mcpCapabilities: ?McpCapabilities = null,
    sessionCapabilities: ?SessionCapabilities = null,
    loadSession: bool = false,
};

const PromptCapabilities = struct {
    image: bool = false,
    audio: bool = false,
    embeddedContext: bool = false,
};

const McpCapabilities = struct {
    http: bool = false,
    sse: bool = false,
};

const SessionCapabilities = struct {};
```

### authenticate

**Request:** client-selected auth method (Banjo ignores params).

**Response (AuthenticateResponse):**
```zig
const AuthenticateResponse = struct {};
```

### session/new

**Request (NewSessionRequest):**
```zig
const NewSessionRequest = struct {
    cwd: []const u8,                         // Required: absolute path to working directory
    _meta: ?std.json.Value = null,
};

const McpServerSse = struct {
    name: []const u8,
    url: []const u8,
    headers: []const HttpHeader = &.{},
};

const EnvVariable = struct {
    name: []const u8,
    value: []const u8,
};
```

**Response (NewSessionResponse):**
```zig
const NewSessionResponse = struct {
    sessionId: []const u8,                   // Required: unique session identifier
    configOptions: ?[]const SessionConfigOption = null,
    models: ?SessionModelState = null,
    modes: ?SessionModeState = null,
};

const SessionConfigOption = struct { // ACP schema (select-only, unstable)
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    type: "select",
    currentValue: []const u8,
    options: []const SessionConfigSelectOption,
};

const SessionConfigSelectOption = struct {
    value: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

const SessionModelState = struct {
    availableModels: []const SessionModel,
    currentModelId: []const u8,
};

const SessionModel = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};
```

Banjo populates `configOptions`, `models`, and `modes`.
ACP currently defines only `type: "select"` for config options (value IDs are strings).

### session/prompt

**Request (PromptRequest):**
```zig
const PromptRequest = struct {
    sessionId: []const u8,                   // Required
    prompt: []const ContentBlock,            // Required: user message content
};

const ContentBlock = struct {
    type: []const u8,                        // "text", "image", "audio", "resource", "resource_link"
    text: ?[]const u8 = null,                // For text blocks
    data: ?[]const u8 = null,                // Base64 for image/audio
    mimeType: ?[]const u8 = null,            // image/png, audio/wav, etc
    uri: ?[]const u8 = null,                 // For resource_link
    name: ?[]const u8 = null,                // For resource_link
    description: ?[]const u8 = null,
    title: ?[]const u8 = null,
    size: ?i64 = null,
    resource: ?EmbeddedResourceResource = null, // For resource blocks
};

// Embedded resource with contents (from Cmd+> / "Add to Agent")
const EmbeddedResourceResource = struct {
    uri: []const u8,                         // e.g. "file:///path/to/file.zig#L42:50"
    text: ?[]const u8 = null,                // File contents
    blob: ?[]const u8 = null,                // Base64 for binary
    mimeType: ?[]const u8 = null,
};
```

**Response (PromptResponse):**
```zig
const PromptResponse = struct {
    stopReason: StopReason,                  // Required
};

const StopReason = enum {
    end_turn,
    cancelled,
    max_tokens,
    max_turn_requests,
    auth_required,
    refusal,
};
```

### session/cancel

Notification (no response):
```zig
const CancelParams = struct {
    sessionId: []const u8,
};
```

### session/set_mode

```zig
const SetModeRequest = struct {
    sessionId: []const u8,
    modeId: []const u8,  // "default", "plan", "acceptEdits", etc.
};
```

Banjo also accepts the legacy `mode` field if `modeId` is missing.

**Response (SetModeResponse):**
```zig
const SetModeResponse = struct {};
```

### session/set_model

```zig
const SetModelRequest = struct {
    sessionId: []const u8,
    modelId: []const u8,  // "sonnet", "opus", "haiku"
};
```

**Response (SetModelResponse):**
```zig
const SetModelResponse = struct {};
```

Banjo sends `current_model_update` when the model changes.

### session/set_config_option

```zig
const SetConfigOptionRequest = struct {
    sessionId: []const u8,
    configId: []const u8, // "auto_resume", "route", "primary_agent"
    value: []const u8, // value ID (string)
};
```

**Response (SetConfigOptionResponse):**
```zig
const SetConfigOptionResponse = struct {
    configOptions: []const SessionConfigOption,
};
```

### session/request_permission

```zig
const PermissionRequest = struct {
    sessionId: []const u8,
    toolCall: ToolCallUpdate,
    options: []const PermissionOption,
};

const ToolCallUpdate = struct {
    toolCallId: []const u8,
    title: ?[]const u8 = null,
    kind: ?ToolKind = null,
    status: ?ToolCallStatus = null,
    rawInput: ?std.json.Value = null,
    rawOutput: ?std.json.Value = null,
    content: ?[]const ToolCallContent = null,
    locations: ?[]const ToolCallLocation = null,
};

const PermissionOption = struct {
    kind: PermissionOptionKind,
    name: []const u8,
    optionId: []const u8,
};

const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,
};

const PermissionResponse = struct {
    outcome: PermissionOutcome,
};

const PermissionOutcome = struct {
    outcome: PermissionOutcomeKind,
    optionId: ?[]const u8 = null,
};

const PermissionOutcomeKind = enum {
    selected,
    cancelled,
};
```

## Session Update Notification (Agent→Client)

Wire format uses `sessionUpdate` as discriminator inside `update` object:

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "...",
    "update": {
      "sessionUpdate": "agent_message_chunk",
      "content": { "type": "text", "text": "Hello!" }
    }
  }
}
```

### Update Types

| sessionUpdate | Description | Key Fields |
|---------------|-------------|------------|
| `agent_message_chunk` | Agent response text | `content: {type, text}` |
| `user_message_chunk` | User message echo | `content: {type, text}` |
| `agent_thought_chunk` | Agent thinking | `content: {type, text}` |
| `tool_call` | Tool invocation | `toolCallId, title, kind, status, rawInput` |
| `tool_call_update` | Tool progress/result | `toolCallId, status, content, rawOutput` |
| `plan` | Todo list | `entries: [{id, content, status}]` |
| `available_commands_update` | Slash commands | `availableCommands` |
| `current_mode_update` | Mode change | `currentModeId` |

Tool call content payload:
```zig
const ToolCallContent = struct {
    type: []const u8,
    content: ?ContentBlock = null,
    terminalId: ?[]const u8 = null,
    path: ?[]const u8 = null,
    oldText: ?[]const u8 = null,
    newText: ?[]const u8 = null,
};
```

See `docs/wire-formats.md` for complete schema.

## Permission Modes

| Mode | Description |
|------|-------------|
| `default` | Ask for each dangerous op |
| `acceptEdits` | Auto-accept file edits |
| `bypassPermissions` | Skip all checks |
| `dontAsk` | Only pre-approved tools |
| `plan` | Planning mode, no execution |

## Stop Reasons

| Reason | Description |
|--------|-------------|
| `end_turn` | Turn completed successfully |
| `max_tokens` | Token limit reached |
| `max_turn_requests` | Request limit reached |
| `refusal` | Agent refused to continue |
| `cancelled` | Cancelled by client |

## Implementation Notes

1. **Required fields**: `cwd` in session/new is REQUIRED

2. **Unknown fields**: Use `ignore_unknown_fields = true` when parsing JSON to handle:
   - `_meta` extensibility field
   - Future protocol additions
   ```zig
   const parsed = std.json.parseFromValue(T, allocator, value, .{
       .ignore_unknown_fields = true,
   });
   ```

3. **Streaming**: Updates are sent as JSON-RPC notifications during prompt processing

4. **Cancellation**: Cancel is a notification (no response). Agent MUST return `stopReason: "cancelled"` in PromptResponse.

5. **Error codes**:
   - Standard JSON-RPC 2.0 codes
   - `-32000`: Authentication required
   - `-32001`: Unsupported protocol version

6. **Content handling**: Banjo merges text + context blocks, resolves `resource_link` via `fs/read_text_file` when available, and includes image/audio metadata as readable context.

## Zed Configuration

Custom agents in `~/.config/zed/settings.json`:

```json
{
  "agent_servers": {
    "Display Name Here": {
      "type": "custom",
      "command": "/path/to/agent",
      "args": ["--flag"],
      "env": {"KEY": "value"}
    }
  }
}
```

- **Key** = display name (not a separate `name` field)
- `type`: `"custom"` for third-party agents
- `command`: executable path
- `args`: optional CLI args array
- `env`: optional env vars object
- No icon customization for custom agents

Restart Zed (Cmd+Q) after config changes.

## Zed Agent Server Extension

Package agents for distribution via Zed's extension system.

### Directory Structure

```
banjo-zed/
├── extension.toml
├── icon/
│   └── banjo.svg      # 16x16 SVG, monochrome
└── README.md
```

### extension.toml

```toml
id = "banjo-acp"
name = "Banjo"
version = "0.1.0"
description = "ACP agent for Claude Code + Codex in Zig"
authors = ["Your Name"]
repository = "https://github.com/user/banjo"

[agent_servers.banjo]
name = "Banjo"
icon = "icon/banjo.svg"

[agent_servers.banjo.targets.darwin-aarch64]
archive = "https://github.com/user/banjo/releases/download/v0.1.0/banjo-darwin-arm64.tar.gz"
cmd = "./banjo"
args = []

[agent_servers.banjo.targets.darwin-x86_64]
archive = "https://github.com/user/banjo/releases/download/v0.1.0/banjo-darwin-x86_64.tar.gz"
cmd = "./banjo"
args = []

[agent_servers.banjo.targets.linux-x86_64]
archive = "https://github.com/user/banjo/releases/download/v0.1.0/banjo-linux-x86_64.tar.gz"
cmd = "./banjo"
args = []
```

### Icon Requirements

- **Format**: SVG only
- **Size**: 16x16 bounding box
- **Padding**: 1-2px recommended
- **Color**: Auto-converted to monochrome (opacity allowed)
- **Optimization**: Use SVGOMG

### Testing Locally

1. Create extension dir with `extension.toml` and icon
2. In Zed: `zed: install dev extension`
3. Select extension directory
4. Agent appears in Agent Panel dropdown

### Publishing

1. Build release binaries for all targets
2. Create GitHub release with archives
3. Update archive URLs in `extension.toml`
4. Submit to Zed extension registry

## NOT in Protocol

- Message editing
- History manipulation
- Re-prompting with edits
