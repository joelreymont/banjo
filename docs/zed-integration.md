# Zed Integration Notes

## Clickable File Links in Agent Output

Agent output supports markdown links that navigate to files in the **active project**.

### Format

```
[@filename (line:col)](file:///absolute/path#Lline:col)
```

### Examples

```markdown
[@main.zig (1:1)](file:///path/to/project/src/main.zig#L1:1)
[@parser.zig (42:50)](file:///path/to/project/src/parser.zig#L42:50)
```

### Limitations

- Only works for files in the project attached to the agent panel
- Absolute paths required in the URI
- Line numbers are 1-based

### How Zed Handles Links

From `zed/crates/agent_ui/src/acp/thread_view.rs`:
1. `render_markdown()` attaches `on_url_click` handler to all markdown
2. `open_link()` parses URI via `MentionUri::parse()`
3. `file://` URIs trigger `workspace.open_path()` with line navigation

URI parsing in `zed/crates/acp_thread/src/mention.rs`:
- `file:///path#L{start}:{end}` - line range selection
- `file:///path?symbol=Name#L{start}:{end}` - symbol reference
- `file:///path` - file only (no line)
- `zed:///agent/thread/{id}` - thread navigation

## Agent Panel @mentions

Users can add context via @mentions:
- `@filename` - file reference
- `@symbol` - function/class/method
- `/symbols` - all symbols in current file

"Add to agent thread" menu creates: `[@file (line:col)](file://...#Lline:col)`

## Slash Commands

Banjo commands:
- `/setup lsp` - re-run setup for banjo-notes LSP (`.zed/settings.json`)
- `/explain` - summarize selected code and insert as note comment
- `/note` - note creation help (use LSP code actions)
- `/notes` - list all notes in project

Claude Code commands (`/version`, `/model`, `/compact`, `/review`, `/clear`) forwarded to Claude Code.

Note: Banjo auto-writes `.zed/settings.json` on first session; reload workspace once to activate the LSP. Banjo never edits global Zed settings.

## Note Creation Workflow

**From code actions (requires LSP):**

1. Position cursor on a comment line
2. Press `Cmd+.` to show code actions
3. Select "Create Banjo Note" or "Convert TODO to Banjo Note"

**From agent panel with `/explain`:**

1. Select code in editor
2. Press `Cmd+>` (Add to agent thread)
3. Type `/explain` and send

The note is inserted as a comment with a unique ID.

## Note Code Actions

Press `Cmd+.` on any line to see available actions:
Requires banjo-notes LSP enabled via `/setup` (or auto-setup + reload).

| Context | Action | Description |
|---------|--------|-------------|
| Comment line | Create Banjo Note | Converts comment to tracked note |
| TODO/FIXME comment | Convert TODO to Banjo Note | Converts with pattern preserved |
| Code line | Add Banjo Note | Inserts note comment above |

## Backlinks (Find References)

Zed does not execute LSP commands, so backlinks are exposed via **Find References**:

1. Place cursor on `@banjo[ID]` or a note link `@[text](ID)`
2. Run **Find References** (`Shift+F12`)
3. Results list all notes that link to that ID

**Keyboard-only flow:**
```
F8              → jump to next note
Cmd+.           → show code actions
Enter           → execute action
```

## Zed Keybindings Reference

| Action | Keybinding | Notes |
|--------|------------|-------|
| Expand selection (syntax node) | `Cmd+Ctrl+Right` | macOS style |
| Shrink selection (syntax node) | `Cmd+Ctrl+Left` | macOS style |
| Move line up | `Alt+Up` | NOT syntax selection |
| Move line down | `Alt+Down` | NOT syntax selection |
| Add to agent thread | `Cmd+>` (`Cmd+Shift+.`) | Inserts Zed URL |
| Toggle agent panel | `Cmd+?` (`Cmd+Shift+/`) | |
| Go to line | `Ctrl+G` | |
| Next diagnostic | `F8` | |
| Code actions | `Cmd+.` | |

## LSP Inline Annotations

### Inlay Hints

Zed supports LSP inlay hints with partial interactivity:

- **Hover**: Tooltips shown via `hover_at_inlay()`
- **Ctrl+Click**: Navigation via `location` field in label parts
- **No direct click handlers**: Would need Zed modification

Structure (`zed/crates/project/src/project.rs`):
```rust
pub struct InlayHintLabelPart {
    pub value: String,
    pub tooltip: Option<InlayHintLabelPartTooltip>,
    pub location: Option<(LanguageServerId, lsp::Location)>,  // Ctrl+Click navigation
}
```

### Code Lenses

**Not implemented in Zed.** Use code actions instead.

### workspace/executeCommand

**Not implemented in Zed.** ([GitHub #13756](https://github.com/zed-industries/zed/issues/13756))

Code actions that use `command` callbacks don't work. Must use `edit` field directly with WorkspaceEdit.

```zig
// WRONG - command callback not executed by Zed
.command = .{ .command = "banjo.createNote", ... }

// RIGHT - edit applied directly
.edit = .{ .documentChanges = &[_]TextDocumentEdit{...} }
```

Affected features:
- "Explain with AI" code action (blocked until Zed implements #13756)
- Any action requiring server-side logic beyond text edits

### Diagnostics

Rendered as inline blocks with code action support. Could potentially trigger agent communication.

### Agent Panel Communication

**No direct LSP→Agent pipeline exists.** Would require:
1. Extend `InlayHintLabelPart` with `command` field
2. Hook click handler to dispatch actions
3. Add action receiver in agent panel

Key files:
- `zed/crates/project/src/project.rs` - InlayHint structures
- `zed/crates/editor/src/inlays/inlay_hints.rs` - Click handling (lines 684-700)
- `zed/crates/agent_ui/src/agent_panel.rs` - Would receive actions

### Alternative: Banjo as LSP Server

Banjo could implement LSP protocol to provide:
- Inlay hints for note markers
- Hover popups with note content
- Ctrl+Click to navigate (but not to agent panel)

Limitation: No way to send data TO agent panel from LSP without Zed modifications.

## WASM Extension Capabilities

Zed WASM extensions are sandboxed with limited capabilities:

**Can do:**
- LSP server configuration
- Slash commands (text output in assistant panel)
- Context servers for AI
- Completion/symbol labels
- Debug adapter setup
- File operations, settings, key-value storage

**Cannot do:**
- Editor buffer decorations/markers
- Click interception on decorations
- Direct tree-sitter access
- Custom UI panels
- Agent panel communication
- SQLite or structured persistence

## Implementation

### Current: Comment-based Notes with LSP

Notes are stored as `@banjo[id]` comments in source files. The LSP server scans comments and publishes diagnostics.

```
LSP Server (banjo --lsp)
  ├─ Scans files for @banjo[id] comment patterns
  ├─ Publishes info-level diagnostics at note locations
  ├─ Code actions to create/convert notes
  └─ Auto-setup configures Zed settings

Agent (banjo --agent)
  ├─ /explain command for Claude-generated summaries
  ├─ Auto-setup writes `.zed/settings.json` on first session
  ├─ /setup lsp to re-run configuration
  └─ Forwards other commands to Claude Code
```

Notes appear as info-level diagnostics. `F8` jumps between notes, `Cmd+.` shows actions.

### Multiple LSPs

Banjo LSP runs alongside language-specific servers (rust-analyzer, zls). Configure in Zed settings:
```json
"languages": {
  "Zig": { "language_servers": ["zls", "banjo-notes"] }
}
```
Diagnostics merge by server ID - both servers' markers displayed together.

## Agent Panel Input

### Triggers

Only two triggers are supported (hardcoded):
- `@` - mentions (files, symbols, threads, etc.)
- `/` - slash commands

**No extensible trigger system** - cannot add `[[` for wiki-links.

### "Add to Agent Thread" Mechanism

Zed's "Add to agent thread" action (`quote_selection`) is a Zed-internal feature:

```rust
// message_editor.rs:785
pub fn insert_selections(&mut self, ...) {
    // 1. Get cursor position in message editor
    let cursor_anchor = editor.selections.newest_anchor().head();

    // 2. Get current selection from active editor (NOT agent panel)
    let completion = PromptCompletionProvider::completion_for_action(
        PromptContextAction::AddSelections, ...
    );

    // 3. Insert formatted mention at cursor
    message_editor.edit([(cursor_anchor..cursor_anchor, completion.new_text)], cx);
}
```

Creates `[@filename (line:col)](file://...)` format at cursor position.

**Key constraint:** This is NOT accessible via ACP. Banjo cannot trigger "insert at cursor" behavior. Banjo can only:
1. Push messages via `session/update` (new message, not at cursor)
2. Respond to slash commands (output in agent response)

### Note Link Insertion Options

Given ACP constraints, viable approaches for hemis:

**Option A: `/note` slash command with autocomplete**
```
/note search-term → autocomplete list → select → note appears in response
```
- Limitation: Only triggers at line start
- Output appears in agent response, not inline in user input
- Slash commands provide `complete_argument()` for dynamic completions

**Option B: Push-based display**
```
User clicks hemi marker (LSP code action)
  → IPC to banjo
  → banjo pushes session/update
  → Note content appears as new agent message
```
- Doesn't interrupt user typing
- No inline insertion, but non-blocking

**Option C: Clipboard helper**
```
/notes list → shows notes with copy-friendly links
User copies link, pastes into message
```
- Manual, but works anywhere in message

**Recommendation:** Option A + B combined. Use `/note` for explicit insertion, LSP clicks for quick viewing.

### Piggybacking on insert_selections

Zed's copy/paste mechanism attaches `ClipboardSelection` metadata:
```rust
pub struct ClipboardSelection {
    pub len: usize,
    pub is_entire_line: bool,
    pub first_line_indent: u32,
    pub file_path: Option<PathBuf>,      // ← Key field
    pub line_range: Option<RangeInclusive<u32>>,
}
```

When pasting with this metadata (multi-line, has file_path, file exists in project), Zed creates a collapsible code block with file reference.

**Banjo cannot write to clipboard** (no ACP method). However, if hemis are stored as real files:

```
.hemis/notes/
├── 123-auth-flow.md
├── 456-parser-notes.md
└── index.json (or SQLite for metadata)
```

Then clipboard mechanism works automatically:
1. User copies from hemi file → `ClipboardSelection` metadata attached by Zed
2. Paste into agent panel → proper crease with file reference
3. "Add to agent thread" (Cmd+') works on hemi files

**Note:** `MentionUri` enum is not extensible without forking. Current variants: File, Directory, Symbol, Thread, TextThread, Rule, Selection, Fetch, PastedImage.

Key files:
- `zed/crates/agent_ui/src/completion_provider.rs` - `completion_for_action()`, mention creation
- `zed/crates/agent_ui/src/acp/message_editor.rs` - `insert_selections()`, cursor handling
- `zed/crates/agent_ui/src/slash_command.rs` - slash command completions

## Related Documentation

- [ACP Protocol](acp-protocol.md) - Agent Client Protocol specification
- [Wire Formats](wire-formats.md) - JSON-RPC message schemas
- [Zed Extension](zed-extension.md) - Extension packaging and publishing
- [Claude Code](claude-code.md) - streaming JSON format
