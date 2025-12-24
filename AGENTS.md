# Banjo - Claude Code ACP Agent in Zig

## Zig 0.15 API Changes

**MUST READ**: `docs/zig-0.15-io-api.md` for ArrayList, I/O, and JSON API changes.

Key changes:
- `ArrayList.init(allocator)` → `.empty`, methods take allocator
- `std.json.encodeJsonString` → `std.json.Stringify.encodeJsonString(str, .{}, writer)`
- `value.jsonStringify(writer)` expects `*std.json.Stringify`, NOT raw writer!
- Use `std.io.Writer.Allocating` for building JSON strings
- Use `std.io.AnyReader`/`AnyWriter` for type-erased streams

## Architecture

```
Zed (ACP Client)
    ↓ JSON-RPC 2.0 over stdio
banjo
    ↓ spawn + stream-json
Claude Code CLI
```

## State Machine Pattern

For complex state machines, use labeled switch with `continue :label`:

```zig
const State = enum { start, parsing, done };

state: switch (State.start) {
    .start => {
        if (condition) continue :state .parsing;
        continue :state .done;
    },
    .parsing => {
        // process...
        continue :state .done;
    },
    .done => {
        return result;
    },
}
```

See `../dixie/src/compiler/parser/lexer.zig` for real example.

## Testing

- Use ohsnap for snapshot tests
- Use quickcheck for property tests
- Run: `zig build test`
