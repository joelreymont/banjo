# Zed Editor Automation Reference

Documentation for automating Zed in hemis-demo demos.

## CLI Options

```bash
zed                          # Open Zed
zed <path>                   # Open file/folder (may reuse existing window)
zed -n <path>                # Open in NEW window (critical for demos)
zed -a <path>                # Add to current workspace
zed --wait <path>            # Block until file closed (for $EDITOR)
zed --foreground             # Run with terminal logging
zed -                        # Read from stdin
```

**For demos**: Always use `zed -n <path>` to ensure a fresh window.

## Keyboard Shortcuts (macOS)

### Diagnostics (Critical for Banjo Demo)
| Action | Shortcut |
|--------|----------|
| Toggle diagnostics panel | `Cmd+Shift+M` |
| Next diagnostic/problem | `F8` |
| Previous diagnostic | `Shift+F8` |

### File Navigation
| Action | Shortcut |
|--------|----------|
| Go to file (file finder) | `Cmd+P` |
| Go to line | `Ctrl+G` |
| Go to symbol | `Cmd+Shift+O` |
| Command palette | `Cmd+Shift+P` |

### Editing
| Action | Shortcut |
|--------|----------|
| Save | `Cmd+S` |
| Save all | `Cmd+Alt+S` |
| Undo | `Cmd+Z` |
| Redo | `Cmd+Shift+Z` |
| Delete line | `Cmd+Shift+K` |
| Duplicate line | `Cmd+Shift+D` |
| New line below | `Cmd+Enter` |

### Window/Panel Management
| Action | Shortcut |
|--------|----------|
| New window | `Cmd+Shift+N` |
| Close window | `Cmd+Shift+W` |
| Close tab | `Cmd+W` |
| Toggle left dock | `Cmd+B` |
| Toggle right dock | `Cmd+Alt+B` |
| Toggle bottom dock | `Cmd+J` |
| Project panel focus | `Cmd+Shift+E` |

### Search
| Action | Shortcut |
|--------|----------|
| Find in file | `Cmd+F` |
| Find and replace | `Cmd+Alt+F` |
| Find in project | `Cmd+Shift+F` |
| Replace in project | `Cmd+Shift+H` |

## LSP Configuration

Zed auto-discovers LSP servers. For the optional Banjo LSP:

### Project-level config (`.zed/settings.json`)
```json
{
  "lsp": {
    "banjo-notes": {
      "binary": {
        "path": "/path/to/banjo",
        "arguments": ["--lsp"]
      }
    }
  },
  "languages": {
    "Zig": {
      "language_servers": ["banjo-notes", "..."]
    }
  }
}
```

### Global config (`~/.config/zed/settings.json`)
Same structure, applies to all projects.

## Accessibility API Limitations

Zed uses GPUI (Rust), not AppKit/Electron. Accessibility support is limited:

- **Window detection**: Works via standard macOS APIs
- **Popup detection**: May not expose popover/modal state
- **Text content**: Limited access to buffer content
- **Cursor position**: Not reliably exposed

**Workaround for demos**: Use timing-based assertions instead of accessibility queries. Trust that keystrokes execute correctly.

## Headless / Remote E2E

Zed does not support a true headless mode; the CLI always launches a GUI window.
For remote testing, run on a macOS host with an active window server and drive it
via hemis-demo/CGEvent (remote desktop or physical session). Expect limited UI
assertions due to GPUI accessibility constraints.

## hemis-demo Key Notation

**CRITICAL**: Special keys must use angle brackets or they're typed literally!

| Wrong | Correct |
|-------|---------|
| `(keys "Enter")` | `(keys "<Enter>")` |
| `(keys "Escape")` | `(keys "<Escape>")` |
| `(keys "Tab")` | `(keys "<Tab>")` |

The parser auto-detects notation type:
- **Vim**: `<C-x>`, `<Enter>`, `<Esc>` - contains `<` and `>`
- **VSCode**: `Cmd+s`, `Ctrl+Shift+p` - contains `+` with Cmd/Ctrl/Alt/Shift
- **Emacs**: `C-x C-s`, `M-x` - contains `C-`, `M-`
- **Plain**: Everything else - typed character by character

## Demo Script Patterns

### Launching Zed for Demo
```lisp
;; In global-setup :shell - runs before app focus
"zed -n /path/to/project"

;; Setup just focuses and resizes
(setup :app zed
       :bounds (100 100 1200 800)
       :wait 5.0)
```

### Diagnostic Navigation (Correct Keys)
```lisp
;; WRONG - Cmd+' is not standard Zed
(keys "Cmd+'")

;; CORRECT - F8 is "Next Problem"
(keys "F8")
(keys "Shift+F8")  ;; Previous
```

### Opening Diagnostics Panel
```lisp
(keys "Cmd+Shift+m")
```

### File Operations
```lisp
;; Go to file
(keys "Cmd+p")
(type "filename")
(keys "Enter")

;; Go to line
(keys "Ctrl+g")
(type "42")
(keys "Enter")
```

## Sources

- [Zed CLI Documentation](https://zed.dev/docs/command-line-interface)
- [Zed Key Bindings](https://zed.dev/docs/key-bindings)
- [Zed Language Configuration](https://zed.dev/docs/configuring-languages)
- [Zed All Actions](https://zed.dev/docs/all-actions)
- [Default macOS Keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/default-macos.json)
