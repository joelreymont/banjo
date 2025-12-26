# Zed Integration Notes

## Clickable File Links in Agent Output

Agent output supports markdown links that navigate to files in the **active project**.

### Format

```
[@filename (line:col)](file:///absolute/path#Lline:col)
```

### Examples

```markdown
[@main.zig (1:1)](file:///Users/joel/Work/banjo/src/main.zig#L1:1)
[@parser.zig (42:50)](file:///Users/joel/Work/project/src/parser.zig#L42:50)
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
- `/version` - show banjo version

CLI commands forwarded to Claude Code (filtered: login, logout, cost, context).

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

## Hemis Integration Options

### Option 1: LSP Server + WASM Extension (Recommended)

**Effort:** 3-4 weeks, no fork needed

```
LSP Server (external process)
  ├─ Tree-sitter parsing + SQLite database
  ├─ Publish diagnostics: "HEMI: {note}" at node positions
  ├─ Code actions to add/edit/delete notes
  └─ Sync on file changes

WASM Extension
  ├─ Register LSP server
  ├─ Slash command for bulk operations
  └─ Settings/config management
```

Notes appear as info-level diagnostics (gutter icons). Click → code action → edit.

### Option 2: Modify Zed Source (Best UX)

**Effort:** 2-3 weeks + fork maintenance

- Add `InlayId::Hemi(uuid)` variant
- Custom gutter icons with click handlers
- Native tree-sitter tracking
- SQLite in project directory
- Full visual control

Requires maintaining Zed fork.

### Option 3: Agent Panel Only (Current Capability)

Use clickable markdown links in agent output:
```markdown
[@file.zig (42:50)](file:///path#L42:50)
```

No inline markers, but notes can link to code locations.

### Option 4: LSP + Agent Panel (Recommended)

Combines LSP markers with agent panel display:

```
┌─────────────────────────────────────────────────────────────┐
│ Editor Buffer                                               │
│  ├─ LSP diagnostics (info-level) show hemi markers          │
│  └─ Click marker → LSP code action → IPC to banjo           │
└─────────────────────┬───────────────────────────────────────┘
                      │ IPC (unix socket)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Banjo (ACP Agent)                                           │
│  ├─ Receives hemi click from LSP                            │
│  ├─ Pushes session/update WITHOUT user prompt               │
│  └─ Streams note content with clickable file links          │
└─────────────────────┬───────────────────────────────────────┘
                      │ session/update notification
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ Agent Panel                                                 │
│  ├─ Displays note content                                   │
│  ├─ Clickable: [@file.zig (42:50)](file:///...#L42:50)      │
│  └─ User can ask Claude to edit/expand note                 │
└─────────────────────────────────────────────────────────────┘
```

**Key insight:** Banjo can push `session/update` at any time after session creation - no user prompt required. Zed's `handle_session_update()` processes updates independently.

**Benefits:**
- Gutter markers visible in editor (via LSP diagnostics)
- Rich note display in agent panel with clickable links
- Claude can help edit/expand notes
- No Zed fork required

**Implementation:**
1. Banjo listens on unix socket for LSP commands
2. LSP server (could be built into banjo) publishes hemi diagnostics
3. Code action click → socket message → banjo pushes to panel
4. SQLite database for note persistence (hemis)

**Concurrent updates:** Banjo can push updates while Claude is streaming (stop button shown). GPUI queues updates on foreground executor - they interleave freely. No locks, no rejection. Consider queuing hemi updates until `status == Idle` for cleaner UX.

**Multiple LSPs:** Banjo LSP can run alongside rust-analyzer/zls. Zed supports multiple LSPs per language via settings:
```json
"language_servers": ["rust-analyzer", "banjo"]
```
Diagnostics merge by server ID - both servers' markers displayed together.

Extensions register LSPs via `register_language_server()` in `extension_lsp_adapter.rs`. Key files:
- `zed/crates/project/src/lsp_store.rs` - multi-server iteration
- `zed/crates/language/src/language_settings.rs` - `language_servers` config
- `zed/crates/language_extension/src/extension_lsp_adapter.rs` - extension registration

## Related Documentation

- [ACP Protocol](acp-protocol.md) - Agent Client Protocol specification
- [Wire Formats](wire-formats.md) - JSON-RPC message schemas
- [Zed Extension](zed-extension.md) - Extension packaging and publishing
- [Claude CLI](claude-cli.md) - CLI streaming JSON format
