# Banjo Duet for Neovim

Banjo Duet runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Codex inside Neovim with a dedicated panel.

## Requirements

- Neovim 0.9+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`claude /login`)

## Installation

### With lazy.nvim

```lua
{
  "joelreymont/banjo",
  opts = {
    binary_path = nil,  -- auto-detected from PATH or common locations
    auto_start = true,
    keymaps = true,
    keymap_prefix = "<leader>a",  -- "a" for agent
    panel = {
      width = 80,
      position = "right",  -- "right" or "left"
    },
  },
}
```

### Local Development

```lua
{
  dir = "/path/to/banjo/nvim",
  opts = {
    binary_path = "/path/to/banjo/zig-out/bin/banjo",
  },
}
```

## Keymaps

Default prefix: `<leader>a`

| Key | Action |
|-----|--------|
| `<leader>ab` | Toggle panel |
| `<leader>as` | Send prompt |
| `<leader>av` | Send with selection (visual mode) |
| `<leader>ac` | Cancel request |
| `<leader>an` | Toggle nudge (auto-continue) |
| `<leader>ah` | Show keybindings help |

### Panel Keymaps

When in the output buffer:

| Key | Action |
|-----|--------|
| `q` | Close panel |
| `i` | Focus input buffer |
| `z` | Toggle fold under cursor |
| `<CR>` | Jump to file:line reference |
| `gf` | Jump to file:line reference |
| `Ctrl-C` | Cancel current request |

When in the input buffer:

| Key | Action |
|-----|--------|
| `<CR>` (insert) | Send prompt |
| `Ctrl-C` | Cancel current request |
| `<Up>` | Previous history |
| `<Down>` | Next history |

## Commands

### Vim Commands

| Command | Description |
|---------|-------------|
| `:BanjoToggle` | Toggle the panel |
| `:BanjoStart` | Start the backend |
| `:BanjoStop` | Stop the backend |
| `:BanjoSend <prompt>` | Send a prompt |
| `:BanjoCancel` | Cancel current request |
| `:BanjoNudge` | Toggle auto-continue |
| `:BanjoClear` | Clear the panel |
| `:BanjoHelp` | Show keybindings |

### Slash Commands

Type these in the input buffer:

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/clear` | Clear conversation |
| `/new` | Start new conversation |
| `/cancel` | Cancel current request |
| `/model <name>` | Set model (sonnet, opus, haiku) |
| `/mode <name>` | Set permission mode |
| `/agent <name>` | Set agent (claude, codex) |
| `/sessions` | List saved sessions |
| `/load <id>` | Load a session |

## Features

### Streaming Output

Responses stream in real-time with:
- Markdown rendering (headers, bold, italic, code)
- Syntax highlighting for code blocks
- Collapsible tool calls (press `z` to toggle)
- File path highlighting (click or `<CR>` to jump)

### Tool Call Display

Tool calls show with:
- Status icon (○ pending, ▶ running, ✓ complete, ✗ failed)
- Tool name in bold
- Formatted input (command for Bash, path for Read, etc.)
- Foldable details

### History

Input history is preserved across sessions:
- `<Up>` / `<Down>` to navigate
- History saved to `~/.local/share/nvim/banjo/history.json`

### Sessions

Conversations can be saved and restored:
- Sessions saved to `~/.local/share/nvim/banjo/sessions/`
- Use `/sessions` to list, `/load <id>` to restore

## Dots Integration

Banjo's killer feature: **automatic continuation** when Claude hits turn limits.

1. Install [Dots](https://github.com/joelreymont/dots) from [releases](https://github.com/joelreymont/dots/releases)
2. Track tasks with `dot add "task description"`
3. When Claude pauses at max turns, Banjo checks for pending dots
4. If pending tasks exist, Banjo automatically continues

Use `/nudge` or `<leader>an` to toggle.

## Configuration Options

```lua
{
  -- Path to banjo binary (auto-detected if nil)
  binary_path = nil,

  -- Start backend automatically on setup
  auto_start = true,

  -- Enable default keymaps
  keymaps = true,

  -- Keymap prefix (default: <leader>a)
  keymap_prefix = "<leader>a",

  -- Panel options
  panel = {
    width = 80,           -- Panel width in columns
    position = "right",   -- "right" or "left"
  },
}
```

## Health Check

Run `:checkhealth banjo` to verify setup:
- Binary found and executable
- Claude Code CLI available
- Connection status
