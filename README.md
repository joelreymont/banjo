# Banjo Duet

![Banjo Duet](assets/logo.png)

Banjo Duet is a Second Brain for your code — run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Codex in your editor.

> **Requires Claude Code or Codex installed.** Run `claude /login` if you haven't already.

## Editor Support

| Editor | Installation |
|--------|--------------|
| **[Zed](docs/zed.md)** | Extensions → "Banjo Duet" → Install |
| **[Neovim](docs/nvim.md)** | `{ "joelreymont/banjo" }` with lazy.nvim |
| **[Emacs](docs/emacs.md)** | `(use-package banjo :load-path "/path/to/banjo/emacs")` |

## Features

- **Auto-continue with Dots** — when Claude pauses at turn limits, Banjo checks for pending [Dots](https://github.com/joelreymont/dots) tasks and automatically continues
- **Auto-resume sessions** — continues your last conversation
- **Dual engine support** — Claude Code and Codex side-by-side
- **Streaming output** — real-time responses with markdown rendering

### Zed-specific

- Code notes as `@banjo[id]` comments
- LSP diagnostics auto-configured on first run (reload workspace once)
- Duet routing: `/claude`, `/codex`, `/duet`

### Neovim-specific

- Dedicated panel with input/output buffers
- Tool call display with folding
- File path navigation (jump to `file:line` references)
- Input history and session management
- Multi-project workspaces (`:BanjoProject`) with tab-scoped buffers

## Dots Integration

Banjo's killer feature: **automatic continuation** when Claude hits turn limits.

1. Install [Dots](https://github.com/joelreymont/dots)
2. Track tasks with `dot add "task description"`
3. When Claude pauses, Banjo sends "continue working on pending dots"

This keeps Claude working autonomously on complex multi-step tasks.

## Architecture

Banjo is written in Zig and implements the [Agent Client Protocol (ACP)](https://agentclientprotocol.com) to communicate with editors.

```
┌─────────────┐     ACP/stdio      ┌──────────────┐
│     Zed     │◄──────────────────►│              │
└─────────────┘                    │              │    stream-json    ┌─────────────┐
                                   │    Banjo     │◄──────────────────►│ Claude Code │
┌─────────────┐   JSON-RPC/WS      │   (agent)    │                    └─────────────┘
│   Neovim    │◄──────────────────►│              │
└─────────────┘                    │              │    JSON-RPC/JSONL  ┌─────────────┐
                                   │              │◄──────────────────►│    Codex    │
                                   └──────────────┘                    └─────────────┘
```

- **Zed**: ACP agent via stdio (JSON-RPC 2.0)
- **Neovim**: WebSocket server with Lua client
- **Claude Code**: Subprocess with streaming JSON
- **Codex**: Subprocess with `app-server` JSON-RPC

### Key Components

| Module | Purpose |
|--------|---------|
| `src/acp/agent.zig` | ACP agent implementation |
| `src/core/claude_bridge.zig` | Claude Code subprocess |
| `src/core/codex_bridge.zig` | Codex app-server subprocess |
| `src/ws/mcp_server.zig` | WebSocket server for Neovim |
| `src/lsp/` | LSP server for code notes |
| `nvim/lua/banjo/` | Neovim Lua plugin |

### Documentation

| Doc | Contents |
|-----|----------|
| [docs/acp-protocol.md](docs/acp-protocol.md) | ACP specification |
| [docs/acp-websocket.md](docs/acp-websocket.md) | ACP WebSocket transport |
| [docs/wire-formats.md](docs/wire-formats.md) | JSON-RPC message schemas |
| [docs/claude-code.md](docs/claude-code.md) | Claude Code CLI integration |
| [docs/codex.md](docs/codex.md) | Codex app-server protocol |
| [docs/zed.md](docs/zed.md) | Zed user guide |
| [docs/nvim.md](docs/nvim.md) | Neovim user guide |
| [docs/emacs.md](docs/emacs.md) | Emacs user guide |

## Development

```bash
git clone https://github.com/joelreymont/banjo.git
cd banjo
zig build test                              # run unit tests
zig build test -Dlive_cli_tests=true        # run live CLI tests
zig build -Doptimize=ReleaseSafe            # build release
```

**Zed:** `Cmd+Shift+P` → `zed: install dev extension` → select `extension/` directory

**Neovim:** Use `dir = "/path/to/banjo/nvim"` in lazy.nvim config

## License

MIT
