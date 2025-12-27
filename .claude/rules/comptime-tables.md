# Comptime String Tables - MANDATORY

## STOP AND CHECK BEFORE WRITING STRING COMPARISONS

**Before writing ANY `mem.eql`, `mem.indexOf`, or `mem.startsWith` with string literals, STOP and use a StaticStringMap instead.**

This is a **blocking rule** - do not proceed with string comparison chains.

## Anti-Patterns (fix immediately)

```zig
// BAD - O(n) linear scan
if (std.mem.eql(u8, name, "foo")) return getFoo();
if (std.mem.eql(u8, name, "bar")) return getBar();

// BAD - checking for multiple patterns
if (mem.indexOf(u8, line, "TODO:") != null) ...
else if (mem.indexOf(u8, line, "FIXME:") != null) ...

// BAD - startsWith chains
if (mem.startsWith(u8, cmd, "/setup")) ...
else if (mem.startsWith(u8, cmd, "/notes")) ...
```

## Correct Pattern

```zig
// GOOD - O(1) perfect hash at comptime
const handlers = std.StaticStringMap(*const fn() T).initComptime(.{
    .{ "foo", &getFoo },
    .{ "bar", &getBar },
});
if (handlers.get(name)) |handler| return handler();

// GOOD - pattern matching with table
const patterns = std.StaticStringMap(PatternType).initComptime(.{
    .{ "TODO:", .todo },
    .{ "FIXME:", .fixme },
    .{ "BUG:", .bug },
});
for (patterns.keys()) |pattern| {
    if (mem.indexOf(u8, line, pattern)) |_| return patterns.get(pattern);
}

// GOOD - command dispatch
const commands = std.StaticStringMap(*const CommandFn).initComptime(.{
    .{ "/setup", &handleSetup },
    .{ "/notes", &handleNotes },
});
```

## When to Use

- **2+ string comparisons** → StaticStringMap
- **Command dispatch** → StaticStringMap with function pointers
- **Pattern matching** → StaticStringMap with enum values
- **Extension lookups** → StaticStringMap (already used in commands.zig)

## In Tests

For checking multiple patterns exist in output, use arrays not repeated indexOf:

```zig
// BAD
try testing.expect(mem.indexOf(u8, content, "\"foo\"") != null);
try testing.expect(mem.indexOf(u8, content, "\"bar\"") != null);

// GOOD
const required = [_][]const u8{ "\"foo\"", "\"bar\"" };
for (required) |pattern| {
    try testing.expect(mem.indexOf(u8, content, pattern) != null);
}
```

## Self-Check

Before committing, grep for these patterns:
```bash
rg "mem.eql\(u8.*\"" --type zig
rg "mem.startsWith\(u8.*\"" --type zig
rg "mem.indexOf.*null\);" --type zig  # repeated indexOf checks
```

Any chain of 2+ should be a table or array loop.
