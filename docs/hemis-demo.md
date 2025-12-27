# hemis-demo Reference

Documentation for the hemis-demo automation framework used for Zed demos.

## Key Notation

**CRITICAL**: Special keys must use angle brackets or VSCode notation, otherwise they're typed literally!

| Wrong | Correct |
|-------|---------|
| `(keys "Enter")` | `(keys "<Enter>")` |
| `(keys "Escape")` | `(keys "<Escape>")` |
| `(keys "Tab")` | `(keys "<Tab>")` |
| `(keys "F8")` | `(keys "<F8>")` |
| `(keys "Down")` | `(keys "<Down>")` |
| `(keys "Up")` | `(keys "<Up>")` |
| `(keys "Backspace")` | `(keys "<Backspace>")` |

**VSCode notation works** (auto-detected when `+` with modifier):
| Example | Works? |
|---------|--------|
| `(keys "Cmd+s")` | ✓ Yes |
| `(keys "Ctrl+g")` | ✓ Yes |
| `(keys "Shift+F8")` | ✓ Yes |
| `(keys "Cmd+Enter")` | ✓ Yes |
| `(keys "Cmd+Down")` | ✓ Yes |

### Auto-Detection Rules

The parser (`KeyNotation.swift`) auto-detects notation type:

- **Vim**: Contains `<` and `>` → `<C-x>`, `<Enter>`, `<Esc>`, `<F8>`
- **VSCode**: Contains `+` with Cmd/Ctrl/Alt/Shift → `Cmd+s`, `Ctrl+Shift+p`
- **Emacs**: Contains `C-`, `M-`, `S-` → `C-x C-s`, `M-x`
- **Plain**: Everything else → typed character by character

### Special Key Codes

From `KeyNotation.swift`:
```swift
"esc": 53, "escape": 53,
"cr": 36, "enter": 36, "return": 36,
"tab": 48,
"bs": 51, "backspace": 51,
"del": 117, "delete": 117,
"up": 126, "down": 125, "left": 123, "right": 124,
"home": 115, "end": 119,
"pageup": 116, "pgup": 116,
"pagedown": 121, "pgdn": 121,
"space": 49, "spc": 49,
"f1": 122, "f2": 120, "f3": 99, "f4": 118,
"f5": 96, "f6": 97, "f7": 98, "f8": 100,
"f9": 101, "f10": 109, "f11": 103, "f12": 111
```

## Script Structure

### Declarations

```lisp
;; Include other scripts
(include "lib/common.demo")

;; Define app
(defapp zed :name "Zed" :bundle-id "dev.zed.Zed")

;; Define variables
(defvar demo-project "/tmp/banjo-demo")

;; Define reusable script
(defscript my-action ()
  (keys "Cmd+s"))
```

### Global Setup

Runs before app launch. Use for file creation, shell commands:

```lisp
(global-setup
  :delete-dirs ("/tmp/demo")
  :create-dirs ("/tmp/demo/src" "/tmp/demo/.zed")
  :create-files (
    ("/tmp/demo/file.txt" "content here")
  )
  :shell (
    "sqlite3 /tmp/demo/db.sqlite 'CREATE TABLE...'"
    "zed -n /tmp/demo"  ;; Launch app via shell
  ))
```

**Important**: `:shell` commands run as actual shell commands. `:commands` in `(setup ...)` types into the app!

### App Setup

Focuses app and sets window bounds:

```lisp
(case *editor*
  (zed
    (setup :app zed
           :bounds (50 50 1500 1000)  ;; x y width height
           :wait 5.0)))  ;; seconds to wait after setup
```

**Note**: Window is created by shell command, then resized by setup. No way to create with initial size.

### Steps

```lisp
(step "Description" :keys "Cmd+S"
  (keys "Cmd+s")
  (sleep 0.5)
  (hide-label))
```

### Assertions

Available assertions (from `IR.swift`):

```lisp
;; Cursor position
(assert-cursor :line 10)
(assert-cursor :line 10 :column 5)
(assert-cursor :symbol "main")

;; Buffer content
(assert-buffer-line :line 5 :contains "fn main")
(assert-buffer-line :line 5 :matches "fn\\s+\\w+")

;; Editor mode
(assert-mode :mode "normal")

;; Popup visibility (unreliable with Zed/GPUI)
(assert-popup :visible true)
(assert-popup :visible true :contains "error")

;; Note assertions
(assert-note-exists :symbol "Config" :contains "TODO")
(assert-note-count :file "main.zig" :exact 4)
(assert-note-stale :symbol "loadConfig" :stale true)
```

**Warning**: Popup and cursor assertions may not work with Zed due to GPUI accessibility limitations.

## Keystroke Controllers

hemis-demo has multiple keystroke delivery methods:

| Controller | Used For | Method |
|------------|----------|--------|
| `KeystrokeController` | Zed, VSCode, any GUI app | CGEvent (macOS native) |
| `NvimKeystrokeController` | Neovim | RPC via socket |
| `EmacsKeystrokeController` | Emacs | emacsclient --eval |

Zed uses `KeystrokeController` (CGEvent-based) - keystrokes sent to focused app.

## Editor Query Clients

For assertions, hemis-demo queries editor state:

| Client | Method | Limitations |
|--------|--------|-------------|
| `NvimQueryClient` | msgpack-rpc | Full access |
| `EmacsQueryClient` | emacsclient | Full access |
| `VSCodeQueryClient` | File-based protocol | Needs extension |
| `ZedQueryClient` | Accessibility API | Limited - GPUI doesn't expose much |

## File Locations

```
hemis-demo/
├── scripts/
│   ├── banjo.demo           # Main demo script
│   ├── config.demo          # Shared config (app defs, global setup)
│   └── lib/
│       ├── common.demo      # Editor-agnostic primitives
│       └── banjo.demo       # Banjo-specific commands
├── Sources/HemisDemo/
│   ├── Automation/
│   │   ├── KeystrokeController.swift
│   │   ├── KeyNotation.swift
│   │   └── ZedQueryClient.swift
│   ├── Compiler/
│   │   ├── SemanticAnalyzer.swift
│   │   ├── IR.swift
│   │   └── IRLowering.swift
│   └── Runtime/
│       ├── IRExecutor.swift
│       └── SetupRunner.swift
```

## Running Demos

```bash
# Run with Zed
swift run hemis-demo banjo --editor zed

# Run with verification (assertions)
swift run hemis-demo banjo --editor zed --verify

# Dump IR without executing
swift run hemis-demo banjo --editor zed --dump-ir

# Run with recording
swift run hemis-demo banjo --editor zed --record
```

## Common Issues

### Keys typed as text
**Symptom**: "Enter" appears in editor instead of pressing Enter
**Fix**: Use `<Enter>` not `Enter`

### Window resizes after appearing
**Cause**: Zed CLI has no window size option
**Mitigation**: hemis-demo resizes via AppleScript after launch

### Assertions fail on Zed
**Cause**: Zed uses GPUI which has limited accessibility API exposure
**Fix**: Remove assertions or use timing-based verification

### Commands typed into app
**Symptom**: Shell command appears as text in editor
**Cause**: Used `:commands` in `(setup ...)` instead of `:shell` in `(global-setup ...)`
**Fix**: Move shell commands to `global-setup :shell`
