# Banjo

![Banjo](assets/logo.jpg)

Claude Code ACP Agent in Zig — run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside [Zed](https://zed.dev)'s Agent Panel.

> **Requires [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated.**
> Run `claude /login` if you haven't already.

## Installation

1. Open Zed → Extensions → Search "Banjo" → Install
2. Open Agent Panel (`Cmd+?`) → Select "Claude Code (Banjo)"

## Features

- **Auto-resume sessions** — automatically continues your last conversation
- Slash commands: `/version`, `/model`, `/compact`, `/review`, `/clear`
- Direct Claude CLI integration (no SDK layer)
- MCP server passthrough

## Configuration

To start fresh sessions instead of auto-resuming:

```json
{
  "agent_servers": {
    "banjo": {
      "env": { "BANJO_AUTO_RESUME": "false" }
    }
  }
}
```

## Development

```bash
git clone https://github.com/joelreymont/banjo.git
cd banjo
zig build test                    # run tests
zig build -Doptimize=ReleaseSafe  # build release
```

Test locally: `Cmd+Shift+P` → `zed: install dev extension` → select this directory.

## License

MIT
