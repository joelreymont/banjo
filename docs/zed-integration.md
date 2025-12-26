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

## Related Documentation

- [ACP Protocol](acp-protocol.md) - Agent Client Protocol specification
- [Wire Formats](wire-formats.md) - JSON-RPC message schemas
- [Zed Extension](zed-extension.md) - Extension packaging and publishing
- [Claude CLI](claude-cli.md) - CLI streaming JSON format
