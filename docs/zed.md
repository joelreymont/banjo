# Banjo Duet for Zed

Banjo Duet runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Codex inside Zed's Agent Panel.

## Installation

1. Open Zed → Extensions → Search "Banjo Duet" → Install
2. Open Agent Panel (`Cmd+?`) → Select "Banjo Duet"

> **Requires Claude Code or Codex installed.** Authenticate in a terminal before using Banjo Duet.

## Features

- **Auto-continue with Dots** — when Claude pauses at turn limits, Banjo checks for pending [Dots](https://github.com/joelreymont/dots) tasks and automatically continues
- **Auto-resume sessions** — automatically continues your last conversation
- **Code notes** — attach notes to code as comments via LSP code actions or `/explain`
- **Auto-setup** — Banjo writes `.zed/settings.json` on first run for LSP diagnostics
- **Duet routing** — `/claude`, `/codex`, `/duet` switch the active routing mode

### Commands

| Command | Description |
|---------|-------------|
| `/version` | Show Claude Code version |
| `/model` | Show/set model |
| `/compact` | Compact conversation |
| `/review` | Review code |
| `/clear` | Clear conversation (restart sessions) |
| `/nudge` | Toggle auto-continue |
| `/claude` | Route to Claude Code |
| `/codex` | Route to Codex |
| `/duet` | Route to both |

## Notes

Banjo lets you attach notes to code as `@banjo[id]` comments. Notes are created via LSP code actions after Banjo writes `.zed/settings.json` and you reload the workspace.

### Quick Start

1. Start a Banjo session — it writes `.zed/settings.json` automatically
2. Reload workspace (`Cmd+Shift+P` → "workspace: reload") to enable LSP notes
3. Place cursor on a comment or code line, press `Cmd+.`, select "Create Banjo Note"
4. Or select code, press `Cmd+>`, type `/explain` to have Claude summarize it

### Creating Notes

**From a comment (LSP)** — Position cursor on any comment line, press `Cmd+.`:
- "Create Banjo Note" — converts the comment to a tracked note
- "Convert TODO to Banjo Note" — shown for TODO/FIXME/HACK comments

**From code (LSP)** — Position cursor on a code line, press `Cmd+.`:
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

Routing defaults:

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

## Dots Integration

Banjo's killer feature: **automatic continuation** when Claude hits turn limits.

1. Install [Dots](https://github.com/joelreymont/dots) from [releases](https://github.com/joelreymont/dots/releases)
2. Track tasks with `dot add "task description"`
3. When Claude pauses at max turns, Banjo checks `dot ls --json`
4. If pending tasks exist, Banjo sends "continue working on pending dots"

Use `/nudge off` to disable, `/nudge on` to re-enable.
