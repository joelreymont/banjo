# Banjo

![Banjo](assets/logo.jpg)

Claude Code ACP Agent in Zig — run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside [Zed](https://zed.dev)'s Agent Panel.

> **Requires [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated.**
> Run `claude /login` if you haven't already.

## Installation

### Zed Extension (Recommended)

1. Open Zed → Extensions → Search "Banjo" → Install
2. Select "Claude Code (Banjo)" in Agent Panel dropdown

### Build from Source

```bash
git clone https://github.com/joelreymont/banjo.git
cd banjo
zig build -Doptimize=ReleaseSafe
```

Binary at `zig-out/bin/banjo`.

Configure in Zed settings (`Cmd+,`):

```json
{
  "agent_servers": {
    "Banjo": {
      "type": "custom",
      "command": "/path/to/banjo/zig-out/bin/banjo"
    }
  }
}
```

## Usage

1. Open Agent Panel: `Cmd+?` (macOS) or `Ctrl+?` (Linux)
2. Click `+` → Select "Banjo" (or "Claude Code (Banjo)" if using extension)

### Slash Commands

| Command | Description |
|---------|-------------|
| `/version` | Show banjo and Claude CLI versions |
| `/model` | Switch Claude model |
| `/compact` | Summarize conversation to reduce context |
| `/review` | Code review current changes |

### Keyboard Shortcut

Add to `keymap.json`:

```json
[
  {
    "bindings": {
      "cmd-alt-b": ["agent::NewExternalAgentThread", { "agent": "Banjo" }]
    }
  }
]
```

### Debugging

View ACP protocol messages:
1. Command Palette (`Cmd+Shift+P`)
2. Run `dev: open acp logs`

## Features

- **Auto-resume sessions** — automatically continues your last Claude conversation
- Direct Claude CLI integration (no SDK layer)
- Hook-based permissions at ACP layer
- Auth handling without session loss
- Message queuing
- MCP server passthrough

## Configuration

To start fresh sessions instead of auto-resuming, add to Zed settings:

```json
{
  "agent_servers": {
    "banjo": {
      "env": {
        "BANJO_AUTO_RESUME": "false"
      }
    }
  }
}
```

Use `/clear` within a session to clear conversation context while keeping the session.

## How It Works

```
Zed (ACP Client) ←→ banjo ←→ Claude CLI
     JSON-RPC 2.0       spawn + stdio
```

Banjo implements the [Agent Client Protocol](https://zed.dev/docs/extensions/agent-servers) to bridge Zed's Agent Panel with the Claude CLI.

## License

MIT
