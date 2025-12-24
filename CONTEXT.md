# Session Context - Banjo ACP Agent

## Current Task
Implementing permissions/settings layer (hooks) for the Banjo ACP agent.

## Progress
- [x] Project structure (build.zig, deps, src/)
- [x] JSON-RPC 2.0 server with Zig 0.15 API
- [x] ACP protocol types and handlers (initialize, session/new, etc.)
- [x] CLI bridge for spawning Claude Code with stream-json
- [x] Session update notifications
- [x] Prompt handling with response streaming
- [x] Auth handling without session loss
- [x] Settings loader (src/settings/loader.zig)
- [ ] Integrate settings into agent for tool permission checking
- [ ] Tool proxies (Read/Write/Edit/Bash via Zed)

## Key Files
- `src/main.zig` - Entry point, stdio setup
- `src/jsonrpc.zig` - JSON-RPC 2.0 parser/serializer
- `src/acp/agent.zig` - ACP request handlers
- `src/acp/protocol.zig` - ACP protocol types
- `src/cli/bridge.zig` - Claude CLI bridge
- `src/settings/loader.zig` - Settings loader (.claude/settings.json)

## Architecture
```
Zed (ACP Client)
    ↓ JSON-RPC 2.0 over stdio
banjo (this)
    ↓ spawn + stream-json
Claude Code CLI
    ↓
Anthropic API
```

## Next Steps
1. Add Settings to Session struct in agent.zig
2. Check permissions in handlePrompt when tool_use detected
3. Implement tool proxies for delegating to Zed

## Decisions Made
- Use arena allocator for ParsedRequest to prevent use-after-free
- Handle auth inline (send text update) instead of throwing error
- Use `std.io.Writer.Allocating` for JSON serialization
- Settings loaded per-session from project's .claude/settings.json

## Resume Command
```bash
cd /Users/joel/Work/claude-code-acp-zig
zig build test  # Verify builds
```
