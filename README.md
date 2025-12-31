# Banjo Duet

![Banjo Duet](assets/logo.png)

Banjo Duet is a Second Brain for your code — an ACP agent in Zig that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Codex inside [Zed](https://zed.dev)'s Agent Panel.

> **Requires Claude Code or Codex installed.**
> Run `claude /login` if you haven't already.

## Installation

1. Open Zed → Extensions → Search "Banjo Duet" → Install
2. Open Agent Panel (`Cmd+?`) → Select "Banjo Duet"

## Features

- **Auto-resume sessions** — automatically continues your last conversation
- **Auto-continue turns** — when Claude Code or Codex hit max-turn limits, Banjo can continue automatically
- **Code notes** — attach notes to code as comments with `/explain`
- **Auto-setup** — `/setup lsp` configures Zed settings automatically
- Claude Code commands: `/version`, `/model`, `/compact`, `/review`, `/clear`
- **Duet routing** — `/claude`, `/codex`, `/duet` switch the active routing mode (default: `/claude` when both engines are available)
- **Codex support** — run Codex prompts side-by-side with Claude Code

## Notes

Banjo Duet lets you attach notes to code as `@banjo[id]` comments. Notes appear as LSP diagnostics.

### Quick Start

1. Run `/setup lsp` in the agent panel — automatically configures Zed settings
2. Write a comment, press `Cmd+.`, select "Create Banjo Note"
3. Or select code, press `Cmd+>`, type `/explain` to have Claude summarize it
4. Use `/claude`, `/codex`, or `/duet` to switch routing mode for new prompts

### Creating Notes

**From a comment** — Position cursor on any comment line, press `Cmd+.`:
- "Create Banjo Note" — converts the comment to a tracked note
- "Convert TODO to Banjo Note" — shown for TODO/FIXME/HACK comments

**From code** — Position cursor on a code line, press `Cmd+.`:
- "Add Banjo Note" — inserts a note comment above the line

**With `/explain`** — Have Claude explain code and insert as a note:
1. Select code in editor
2. Press `Cmd+>` to add reference to agent panel
3. Type `/explain` and send

### Navigating Notes

- `F8` — Jump to next note
- `Cmd+.` — Show code actions for the note under cursor

### Note Format

Notes are stored as comments in your code:
```
// @banjo[abc123def456] This function handles authentication
```

Notes can link to each other using `@[display](target-id)` syntax. Type `@[` to trigger autocomplete.

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

Routing defaults (optional):

```json
{
  "agent_servers": {
    "banjo": {
      "env": {
        "BANJO_ROUTE": "claude",
        "BANJO_PRIMARY_AGENT": "claude"
      }
    }
  }
}
```

## Dots Integration (Optional)

Banjo can auto-continue when Claude Code or Codex pause at max-turn limits by
checking for pending tasks with [Dots](http://github.com/joelreymont/dots).
Install `dot` and keep tasks in `dot ls --json` so Banjo knows when to continue.

## Development

```bash
git clone https://github.com/joelreymont/banjo.git
cd banjo
zig build test                    # run tests
zig build -Doptimize=ReleaseSafe  # build release
```

Test locally: `Cmd+Shift+P` → `zed: install dev extension` → select this repo root (not `extension/`).

## License

MIT
