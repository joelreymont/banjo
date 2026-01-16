# Banjo Duet for Emacs

Banjo Duet runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and Codex inside Emacs with a dedicated panel.

## Requirements

- Emacs 28.1+
- [websocket.el](https://github.com/ahyatt/emacs-websocket) package
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (`claude /login`)

## Installation

### With use-package

```elisp
(use-package banjo
  :load-path "/path/to/banjo/emacs"
  :commands (banjo-start banjo-send banjo-toggle)
  :init
  (banjo-setup-keybindings)
  :custom
  (banjo-binary "/path/to/banjo/zig-out/bin/banjo")
  (banjo-panel-width 80)
  (banjo-panel-position 'right))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/banjo/emacs")
(require 'banjo)
(setq banjo-binary "/path/to/banjo/zig-out/bin/banjo")
(banjo-setup-keybindings)
```

### Doom Emacs

**~/.doom.d/packages.el**
```elisp
(package! websocket)
(package! banjo :recipe (:local-repo "/path/to/banjo/emacs"))
```

**~/.doom.d/config.el**
```elisp
(use-package! banjo
  :commands (banjo-start banjo-send banjo-toggle banjo-cancel)
  :init
  (setq banjo-binary "/path/to/banjo/zig-out/bin/banjo")

  ;; Leader keybindings like nvim: SPC a ...
  (map! :leader
        (:prefix ("a" . "ai agent")
         :desc "Toggle panel"      "b" #'banjo-toggle
         :desc "Send prompt"       "s" #'banjo-send
         :desc "Send region"       "v" #'banjo-send-region
         :desc "Cancel"            "c" #'banjo-cancel
         :desc "Set mode"          "m" #'banjo-set-mode
         :desc "Set model"         "M" #'banjo-set-model
         :desc "Set engine"        "e" #'banjo-set-engine
         :desc "Start"             "S" #'banjo-start
         :desc "Stop"              "q" #'banjo-stop))

  ;; Panel buffer keybindings (evil normal mode)
  (after! evil
    (evil-define-key 'normal banjo-mode-map
      "q" #'banjo--hide-panel
      "gr" #'banjo-toggle
      (kbd "C-c") #'banjo-cancel)))
```

Then run `doom sync`.

## Usage

1. **Start**: `M-x banjo-start` or `C-c a s`
2. **Send prompt**: `M-x banjo-send` or `C-c a p` — enter prompt in minibuffer
3. **Send with code**: Select region, then `M-x banjo-send-region` or `C-c a r`
4. **Cancel**: `M-x banjo-cancel` or `C-c a c`
5. **Toggle panel**: `M-x banjo-toggle` or `C-c a t`

Output streams to the `*banjo*` buffer in a side panel.

### Permission Prompts

When Claude needs to run a tool (e.g., Bash, Edit), you'll see in the minibuffer:

```
Allow Bash? (y=yes, a=always, n=no):
```

- `y` — allow this once
- `a` — always allow this tool
- `n` — deny (cancels the request)

### Tool Call Display

Tool calls appear inline:
```
○ Read src/main.zig → ✓
○ Bash npm test → ✗
```

## Keybindings

### Standard Emacs

Default prefix: `C-c a` (set via `banjo-setup-keybindings`)

| Key | Command | Description |
|-----|---------|-------------|
| `C-c a s` | `banjo-start` | Start daemon and connect |
| `C-c a q` | `banjo-stop` | Stop daemon |
| `C-c a p` | `banjo-send` | Send prompt |
| `C-c a r` | `banjo-send-region` | Send region with prompt |
| `C-c a c` | `banjo-cancel` | Cancel current request |
| `C-c a t` | `banjo-toggle` | Toggle panel |
| `C-c a m` | `banjo-set-mode` | Set permission mode |
| `C-c a M` | `banjo-set-model` | Set model (sonnet/opus/haiku) |
| `C-c a e` | `banjo-set-engine` | Set engine (claude/codex) |

### Doom Emacs (nvim-style)

With the Doom config above, keybindings match Neovim's `<leader>a` prefix:

| Key | Command | Description |
|-----|---------|-------------|
| `SPC a b` | `banjo-toggle` | Toggle panel |
| `SPC a s` | `banjo-send` | Send prompt |
| `SPC a v` | `banjo-send-region` | Send region (visual select first) |
| `SPC a c` | `banjo-cancel` | Cancel current request |
| `SPC a m` | `banjo-set-mode` | Set permission mode |
| `SPC a M` | `banjo-set-model` | Set model |
| `SPC a e` | `banjo-set-engine` | Set engine |
| `SPC a S` | `banjo-start` | Start daemon |
| `SPC a q` | `banjo-stop` | Stop daemon |

In the `*banjo*` buffer: `q` closes panel, `C-c` cancels request.

## Commands

| Command | Description |
|---------|-------------|
| `banjo-start` | Start daemon and connect |
| `banjo-stop` | Stop daemon and disconnect |
| `banjo-send` | Send prompt from minibuffer |
| `banjo-send-region` | Send selected region with prompt |
| `banjo-cancel` | Cancel current request |
| `banjo-toggle` | Toggle the panel |
| `banjo-set-mode` | Set permission mode (default/acceptEdits/bypassPermissions/plan) |
| `banjo-set-model` | Set model (sonnet/opus/haiku) |
| `banjo-set-engine` | Set engine (claude/codex) |

## Configuration

```elisp
;; Panel settings
(setq banjo-panel-width 100)
(setq banjo-panel-position 'left)  ; or 'right

;; Binary path (auto-detected if on PATH)
(setq banjo-binary "banjo")
```

## Mode Line

When connected, shows: `[claude/sonnet (default)]`

When disconnected, shows: `[disconnected]`

## Dots Integration

Banjo's killer feature: **automatic continuation** when Claude hits turn limits.

1. Install [Dots](https://github.com/joelreymont/dots)
2. Track tasks with `dot add "task description"`
3. When Claude pauses at max turns, Banjo checks for pending dots
4. If pending tasks exist, Banjo automatically continues
