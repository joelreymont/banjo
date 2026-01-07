# Banjo Duet

![Banjo Duet](assets/logo.png)

Banjo Duet is a Second Brain for your code — run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Codex in your editor.

> **Requires Claude Code or Codex installed.** Run `claude /login` if you haven't already.

## Editor Support

| Editor | Installation |
|--------|--------------|
| **[Zed](docs/zed.md)** | Extensions → "Banjo Duet" → Install |
| **[Neovim](docs/nvim.md)** | `{ "joelreymont/banjo" }` with lazy.nvim |

## Features

- **Auto-continue with Dots** — when Claude pauses at turn limits, Banjo checks for pending [Dots](https://github.com/joelreymont/dots) tasks and automatically continues
- **Auto-resume sessions** — continues your last conversation
- **Dual engine support** — Claude Code and Codex side-by-side
- **Streaming output** — real-time responses with markdown rendering

### Zed-specific

- Code notes as `@banjo[id]` comments with LSP diagnostics
- Auto-setup with `/setup lsp`
- Duet routing: `/claude`, `/codex`, `/duet`

### Neovim-specific

- Dedicated panel with input/output buffers
- Tool call display with folding
- File path navigation (jump to `file:line` references)
- Input history and session management

## Dots Integration

Banjo's killer feature: **automatic continuation** when Claude hits turn limits.

1. Install [Dots](https://github.com/joelreymont/dots)
2. Track tasks with `dot add "task description"`
3. When Claude pauses, Banjo sends "continue working on pending dots"

This keeps Claude working autonomously on complex multi-step tasks.

## Development

```bash
git clone https://github.com/joelreymont/banjo.git
cd banjo
zig build test                    # run tests
zig build -Doptimize=ReleaseSafe  # build release
```

**Zed:** `Cmd+Shift+P` → `zed: install dev extension` → select repo root

**Neovim:** Use `dir = "/path/to/banjo/nvim"` in lazy.nvim config

## License

MIT
