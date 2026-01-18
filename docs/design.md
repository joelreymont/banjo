# Banjo Design Document

## Overview

Banjo is an ACP (Agent Client Protocol) agent written in Zig that bridges code editors to Claude Code and Codex CLI tools. It enables AI coding assistance in Zed, Neovim, and Emacs.

## Architecture

```
┌─────────────┐     ACP/stdio      ┌──────────────┐
│     Zed     │◄──────────────────►│              │
└─────────────┘                    │              │    stream-json    ┌─────────────┐
                                   │    Banjo     │◄──────────────────►│ Claude Code │
┌─────────────┐   JSON-RPC/WS      │   (agent)    │                    └─────────────┘
│   Neovim    │◄──────────────────►│              │
└─────────────┘                    │              │    JSON-RPC/JSONL  ┌─────────────┐
                                   │              │◄──────────────────►│    Codex    │
┌─────────────┐   JSON-RPC/WS      └──────────────┘                    └─────────────┘
│    Emacs    │◄──────────────────►
└─────────────┘
```

## Run Modes

Banjo operates in three modes selected via CLI flags:

| Mode | Flag | Transport | Use Case |
|------|------|-----------|----------|
| Agent | `--agent` (default) | stdio | Zed ACP integration |
| Daemon | `--daemon` | WebSocket | Neovim/Emacs clients |
| LSP | `--lsp` | stdio | Code notes (experimental) |

## Core Modules

### Entry Point (`src/main.zig`)

Parses CLI args, selects run mode, initializes logging.

### ACP Agent (`src/acp/agent.zig`)

Implements ACP protocol for Zed. Key responsibilities:

- **Session management**: Create/resume sessions with `session/new`, `unstable_resumeSession`
- **Prompt handling**: Route prompts to Claude/Codex bridges
- **Streaming**: Forward `session/update` notifications (text chunks, tool calls, plans)
- **Permissions**: Handle `session/request_permission` requests from CLI
- **Tool proxy**: Forward `fs/*` and `terminal/*` requests to editor

State machine:
```
Uninitialized → Initialized → SessionActive → Processing ⟲
                                    ↓
                              Cancelled/Completed
```

### Claude Bridge (`src/core/claude_bridge.zig`)

Spawns `claude` CLI in `--input-format stream-json --output-format stream-json` mode.

Input: `{"type":"user","message":{"role":"user","content":"..."}}`

Output events:
- `system/init` - Session created, tools available
- `system/auth_required` - Need `claude /login`
- `assistant` - Response content blocks (text, tool_use, tool_result)
- `stream_event/content_block_delta` - Streaming text/thinking
- `result` - Turn complete with stop reason

### Codex Bridge (`src/core/codex_bridge.zig`)

Spawns `codex app-server` and speaks JSON-RPC over JSONL.

Flow:
1. `initialize` → `initialized` notification
2. `thread/start` → `thread/started` notification
3. `turn/start` → streaming `item/*` notifications → `turn/completed`

Approval requests: `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`

### WebSocket Server (`src/ws/mcp_server.zig`)

Daemon mode server for Neovim/Emacs. Listens on random port, writes lockfile.

- **Lockfile**: `~/.claude/ide/<port>.lock` (port is the filename). JSON contains `pid`, `workspaceFolders`, `ideName`, `transport`.
- **Protocol**: JSON-RPC 2.0 over WebSocket frames
- **ACP transport**: Wraps Agent with WebSocket reader/writer (`src/acp/ws_transport.zig`)

### Tool Proxy (`src/tools/proxy.zig`)

Routes tool requests from CLI to editor:

| ACP Method | Description |
|------------|-------------|
| `fs/read_text_file` | Read file via editor |
| `fs/write_text_file` | Write file via editor |
| `terminal/create` | Execute command |
| `terminal/output` | Get terminal output |
| `terminal/wait_for_exit` | Block until command exits |
| `terminal/kill` | Terminate command |

## Editor Integrations

### Zed

**Transport**: stdio (ACP native)

**Extension**: `extension/` directory with `extension.toml`

**Flow**:
1. Zed spawns `banjo --agent`
2. Sends `initialize`, `session/new`, `session/prompt`
3. Receives `session/update` notifications
4. Responds to `session/request_permission` requests

### Neovim

**Transport**: WebSocket to daemon

**Plugin**: `nvim/lua/banjo/` (Lua)

**Components**:
- `bridge.lua` - WebSocket client, JSON-RPC encoding
- `panel.lua` - Split window with input/output buffers
- `display.lua` - Markdown rendering, tool call folding
- `state.lua` - Session state, connection status

**Flow**:
1. `:BanjoStart` spawns daemon or connects to existing (via lockfile)
2. `:BanjoSend` sends `session/prompt`
3. Panel updates with streamed responses

### Emacs

**Transport**: WebSocket to daemon

**Package**: `emacs/banjo.el` (Elisp)

**Components**:
- `banjo-mode` - Major mode for output buffer
- `banjo--websocket` - Connection via `websocket.el`
- `banjo--handle-message` - JSON-RPC dispatch
- `banjo--handle-permission-request` - Minibuffer prompts

**Flow**:
1. `banjo-start` spawns daemon or connects
2. `banjo-send` prompts via minibuffer
3. `*banjo*` buffer shows streamed output

**Keybindings** (auto-configured):
- Doom Emacs: `SPC a` prefix
- Standard Emacs: `C-c a` prefix

## Protocol Details

### ACP (Agent Client Protocol)

JSON-RPC 2.0 over stdio/WebSocket. See `docs/acp-protocol.md` and `docs/acp-websocket.md`.

Key methods:
- `initialize` - Capability negotiation
- `session/new` - Create session with `cwd`
- `session/prompt` - Send user message
- `session/update` - Stream progress (notification)
- `session/request_permission` - Ask for tool approval

### Session Updates

Discriminated union via `sessionUpdate` field:

| Type | Content |
|------|---------|
| `agent_message_chunk` | `{type, text}` |
| `agent_thought_chunk` | `{type, text}` (extended thinking) |
| `tool_call` | `{toolCallId, title, kind, status, rawInput}` |
| `tool_call_update` | `{toolCallId, status, content, rawOutput}` |
| `plan` | `{entries: [{id, content, status}]}` |
| `current_mode_update` | `{currentModeId}` |
| `current_model_update` | `{currentModelId}` |

### Permission Modes

| Mode | Behavior |
|------|----------|
| `default` | Ask for each dangerous tool |
| `acceptEdits` | Auto-accept file edits |
| `bypassPermissions` | Skip all checks |
| `plan` | Planning only, no execution |

## Auto-Continue (Dots Integration)

When Claude hits `max_turn_requests`, Banjo checks for pending dots:

```bash
dot ls --json
```

If pending tasks exist, Banjo sends a nudge prompt to continue working.

## Session Persistence

- **Session ID**: Stored in `.banjo/` directory
- **Auto-resume**: Enabled by default, respects `BANJO_AUTO_RESUME` env
- **Context reload**: `context_reloaded` stop reason triggers continuation

## Key Files

| File | Purpose |
|------|---------|
| `src/main.zig` | CLI entry, mode dispatch |
| `src/acp/agent.zig` | ACP protocol implementation |
| `src/acp/protocol.zig` | ACP type definitions |
| `src/core/claude_bridge.zig` | Claude Code subprocess |
| `src/core/codex_bridge.zig` | Codex app-server subprocess |
| `src/ws/mcp_server.zig` | WebSocket server for nvim/emacs |
| `src/ws/handler.zig` | Daemon message routing |
| `src/tools/proxy.zig` | Editor tool forwarding |
| `src/jsonrpc.zig` | JSON-RPC 2.0 parser/writer |
| `nvim/lua/banjo/` | Neovim Lua plugin |
| `emacs/banjo.el` | Emacs Lisp client |
| `extension/` | Zed extension manifest |

## Build

```bash
zig build                              # debug
zig build -Doptimize=ReleaseSafe       # release
zig build test                         # unit tests
zig build test -Dlive_cli_tests=true   # integration tests
```

## Testing

- **Snapshots**: `ohsnap` for struct serialization
- **Property tests**: `zcheck` for invariants
- **Live tests**: Real Claude/Codex subprocess tests (requires auth)
- **Lua tests**: `busted` for Neovim plugin
