# Banjo

A Zig implementation of the Claude Code ACP adapter, enabling [Claude Code](https://www.anthropic.com/claude-code) integration with [Zed](https://zed.dev) via the [Agent Client Protocol](https://agentclientprotocol.com/).

## Features

- Direct communication with Claude Code CLI (no SDK layer)
- Session resume support
- Hook-based permissions at ACP layer
- Auth handling without session loss
- Message queuing (no interruption)
- MCP server passthrough

## Building

```bash
zig build
```

The binary will be at `zig-out/bin/banjo`.

## Zed Setup

### 1. Build the binary

```bash
cd /path/to/banjo
zig build -Doptimize=ReleaseFast
```

### 2. Configure Zed

Open Zed settings (`Cmd+,` or `Ctrl+,`) and add:

```json
{
  "agent_servers": {
    "Banjo": {
      "type": "custom",
      "command": "/path/to/banjo/zig-out/bin/banjo",
      "args": [],
      "env": {}
    }
  }
}
```

Or symlink to a location in your PATH:

```bash
ln -s /path/to/banjo/zig-out/bin/banjo ~/.local/bin/banjo
```

Then in Zed settings:

```json
{
  "agent_servers": {
    "Banjo": {
      "type": "custom",
      "command": "banjo",
      "args": [],
      "env": {}
    }
  }
}
```

### 3. Start a session

1. Open Agent Panel: `Cmd+?` (macOS) or `Ctrl+?` (Linux)
2. Click the `+` button in the top-right
3. Select "Banjo"

### Debugging

View ACP protocol messages:
1. Open Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`)
2. Run `dev: open acp logs`

### Keyboard Shortcut

Add to your `keymap.json`:

```json
[
  {
    "bindings": {
      "cmd-alt-b": ["agent::NewExternalAgentThread", { "agent": "Banjo" }]
    }
  }
]
```

## Requirements

- [Claude Code CLI](https://claude.ai/code) installed and in PATH
- Valid Claude subscription or API key (run `claude /login` to authenticate)

## License

Apache-2.0
