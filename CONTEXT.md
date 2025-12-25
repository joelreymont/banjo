# Banjo - Current State

## Completed

All issues from review fixed:
- P0: UAF in agent.zig (stop_reason duplication before msg.deinit)
- P0: Memory leak in handleResumeSession (check existing session first)
- P1: Deleted unused isRunning()
- P1: Use sid_copy instead of session_id from request arena
- P2: Security - log settings parse failure at error level
- P2: DRY - Typed JSON param structs with parseFromValue
- P2: DRY - handleInitialize uses writeTypedResponse (no double serialize)

Zig 0.15 API migration complete:
- ArrayList unmanaged API
- StdIo PascalCase enums
- File.reader() buffer requirement
- fmt.bytesToHex
- std.json.Stringify for writing
- std.json.parseFromValue for typed parsing

## Key Patterns

1. **JSON parsing**: Define typed structs, use `std.json.parseFromValue(T, allocator, value, .{})`
2. **JSON writing**: Use `std.json.Stringify` or `jsonrpc.Writer.writeTypedResponse`
3. **Error handling**: Propagate errors with try, log failures, never silently ignore

## Files

- `src/main.zig` - Entry point, event loop
- `src/jsonrpc.zig` - JSON-RPC 2.0 protocol
- `src/acp/agent.zig` - ACP handler (typed param structs at top)
- `src/acp/protocol.zig` - ACP protocol types
- `src/cli/bridge.zig` - Claude CLI subprocess
- `src/settings/loader.zig` - .claude/settings.json loader
- `src/tools/proxy.zig` - Stub for bidirectional tool proxy

## Next Steps

1. Implement bidirectional ACP for tool proxy (fs/terminal delegation to Zed)
2. Add tests for ACP message handling
3. Integration testing with actual Zed
