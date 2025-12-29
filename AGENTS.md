# Banjo - ACP Agent for Claude Code + Codex in Zig

## Must-Know (Zig 0.15)

- Read `docs/zig-0.15-api.md` (ArrayList, I/O, JSON changes).
- Allocator first (after self). If an arena is required, name it `arena`.
- `ArrayList` is unmanaged; pass allocator to methods. `StringHashMap` still uses `.init(allocator)`.
- No `std.io.getStdOut()`; use stdout writer.
- Run `zig fmt src/` before committing.

## JSON (Required)

- Define typed structs and parse with `std.json.parseFromValue`.
- Avoid manual `.object.get(...)` chains.
- Use `std.json.Stringify` (`beginObject/objectField/endObject`) and `std.io.Writer.Allocating`.

## String Matching (Mandatory)

- Any 2+ literal comparisons with `mem.eql`, `mem.indexOf`, or `mem.startsWith` must use a `StaticStringMap` or a loop over a pattern list.
- Command dispatch must be a `StaticStringMap`.

## Comments

- Keep comments minimal.
- No ASCII art separators; for section headers use simple `//` line(s).

## State Machines

- For complex state machines, use a labeled switch with `continue :state`.

## Testing

- Primary: snapshots (ohsnap) + property tests (quickcheck) with a real oracle.
- `std.testing` only for trivial cases, error paths, or when no structured output exists.
- Always run `zig build test` after major changes or adding tests.
