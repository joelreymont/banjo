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
| `fs/readTextFile` | Read file |
| `fs/writeTextFile` | Write file |

### Terminal (Agent→Client)
| Method | Description |
|--------|-------------|
| `terminal/create` | Execute command |
| `terminal/output` | Get output |
| `terminal/waitForExit` | Wait completion |
| `terminal/kill` | Terminate |
| `terminal/release` | Release resources |

## Request/Response Schemas

### initialize

**Request (InitializeRequest):**
```zig
const InitializeParams = struct {
    protocolVersion: u32,                    // Required: protocol version (currently 1)
    clientInfo: ?Implementation = null,      // Optional: {name, version}
    clientCapabilities: ?ClientCapabilities = null,
    _meta: ?std.json.Value = null,           // Reserved for extensibility
};

const ClientCapabilities = struct {
    fs: ?FsCapability = null,
    terminal: bool = false,
};

const FsCapability = struct {
    readTextFile: bool = false,
    writeTextFile: bool = false,
};
```

**Response (InitializeResponse):**
```zig
const InitializeResult = struct {
    protocolVersion: u32,
    agentInfo: ?Implementation = null,
    agentCapabilities: AgentCapabilities,
    authMethods: []const AuthMethod = &.{},
};
```

### session/new

**Request (NewSessionRequest):**
```zig
const NewSessionParams = struct {
    cwd: []const u8,                         // Required: absolute path to working directory
    mcpServers: []const McpServer = &.{},    // Required: MCP servers (can be empty)
    _meta: ?std.json.Value = null,
};

const McpServer = union(enum) {
    stdio: McpServerStdio,
    http: McpServerHttp,
    sse: McpServerSse,
};

const McpServerStdio = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: ?std.json.ObjectMap = null,
};

const McpServerHttp = struct {
    name: []const u8,
    url: []const u8,
};
```

**Response (NewSessionResponse):**
```zig
const NewSessionResult = struct {
    sessionId: []const u8,                   // Required: unique session identifier
    configOptions: ?[]const ConfigOption = null,
    models: ?SessionModelState = null,
    modes: ?SessionModeState = null,
};
```

### session/prompt

**Request (PromptRequest):**
```zig
const PromptParams = struct {
    sessionId: []const u8,                   // Required
    prompt: []const ContentBlock,            // Required: user message content
    _meta: ?std.json.Value = null,
};

const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    context: EmbeddedContext,
};

const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};
```

**Response (PromptResponse):**
```zig
const PromptResult = struct {
    stopReason: StopReason,                  // Required
    _meta: ?std.json.Value = null,
};

const StopReason = enum {
    end_turn,
    max_tokens,
    max_turn_requests,
    refusal,
    cancelled,
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
const SetModeParams = struct {
    sessionId: []const u8,
    mode: []const u8,  // "default", "plan", "acceptEdits", etc.
};
```

## Session Update Notification (Agent→Client)

```zig
const SessionUpdate = struct {
    sessionId: []const u8,
    update: Update,
};

const Update = struct {
    kind: UpdateKind,
    content: ?[]const u8 = null,
    title: ?[]const u8 = null,
    // ... other fields based on kind
};

const UpdateKind = enum {
    text,
    tool_use,
    tool_result,
    thinking,
    plan,
    error,
};
```

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

1. **Required fields**: `mcpServers` in session/new is REQUIRED (can be empty array `[]`)

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
id = "banjo"
name = "Banjo"
version = "0.1.0"
description = "Claude Code ACP agent in Zig"
authors = ["Your Name"]
repository = "https://github.com/user/banjo"

[agent_servers.banjo]
name = "Banjo"
icon = "icon/banjo.svg"

[agent_servers.banjo.targets.darwin-aarch64]
archive = "https://github.com/user/banjo/releases/download/v0.1.0/banjo-darwin-arm64.tar.gz"
cmd = "./banjo"
args = ["--output-format", "stream-json", "--input-format", "stream-json"]

[agent_servers.banjo.targets.darwin-x86_64]
archive = "https://github.com/user/banjo/releases/download/v0.1.0/banjo-darwin-x86_64.tar.gz"
cmd = "./banjo"
args = ["--output-format", "stream-json", "--input-format", "stream-json"]

[agent_servers.banjo.targets.linux-x86_64]
archive = "https://github.com/user/banjo/releases/download/v0.1.0/banjo-linux-x86_64.tar.gz"
cmd = "./banjo"
args = ["--output-format", "stream-json", "--input-format", "stream-json"]
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
