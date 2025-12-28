# Banjo - ACP Agent for Claude Code + Codex in Zig

## Zig 0.15 API Changes

**MUST READ**: `docs/zig-0.15-api.md` for ArrayList, I/O, and JSON API changes.

Key changes:
- `ArrayList.init(allocator)` → `.empty`, methods take allocator
- **JSON parsing**: Use `std.json.parseFromValue(T, allocator, value, .{})` to parse into typed structs
- **JSON writing**: Use `std.json.Stringify` with `beginObject/objectField/write/endObject`
- Use `std.io.Writer.Allocating` for building JSON strings

## JSON Pattern (REQUIRED)

**ALWAYS** define typed structs for JSON params and use `parseFromValue`:

```zig
// Define schema as struct
const PromptParams = struct {
    sessionId: []const u8,
    prompt: ?[]const u8 = null,
};

// Parse in handler
const parsed = std.json.parseFromValue(PromptParams, allocator, json_value, .{}) catch {
    // handle error
};
defer parsed.deinit();
const params = parsed.value;
// Use params.sessionId, params.prompt
```

**NEVER** manually extract fields with `params.object.get("field")` chains.

## Architecture

```
Zed (ACP Client)
    ↓ JSON-RPC 2.0 over stdio
banjo
    ↓ spawn + stream-json
Claude Code
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

### Property Tests (MANDATORY for data transformations)

Use `src/util/quickcheck.zig` for property-based testing. Test invariants, not specific cases:

```zig
const quickcheck = @import("util/quickcheck.zig");

test "property: addition is commutative" {
    try quickcheck.check(struct {
        fn prop(args: struct { a: i16, b: i16 }) bool {
            const sum1 = @as(i32, args.a) + @as(i32, args.b);
            const sum2 = @as(i32, args.b) + @as(i32, args.a);
            return sum1 == sum2;
        }
    }.prop, .{});
}
```

Quickcheck generates random values and shrinks failures to minimal counterexamples.
**DO NOT** write unit tests with hardcoded values when a property test is possible.

### Snapshot Tests

Use ohsnap for testing complex output (JSON responses, formatted strings):

```zig
const ohsnap = @import("ohsnap");
try ohsnap.snap(@src(), actual_output);
```

### Run Tests

```bash
zig build test
```
