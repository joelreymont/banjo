# Banjo - ACP Agent for Claude Code + Codex in Zig

## Must-Know (Zig 0.15)

- Read `docs/zig-0.15-api.md` (ArrayList, I/O, JSON changes).
- Allocator MUST be the first parameter (after self). If an arena allocator is used, the first parameter MUST be named `arena`.
- `ArrayList` is unmanaged; pass allocator to methods. `StringHashMap` still uses `.init(allocator)`.
- Import modules once; use the namespace instead of repeating `@import("x.zig").Type`.
- When adding multiple known items to an ArrayList, build a static array and `appendSlice` once.
- No `std.io.getStdOut()`; use stdout writer.
- Run `zig fmt src/` before committing.
- Do not mask errors: no `catch unreachable`/`orelse unreachable` for fallible ops. Use `try` and return error unions.
- Prefer `switch` on a kind/enum over chained predicate checks for type dispatch.

## JSON (Required)

- ALWAYS use typed structs for JSON parsing and serialization.
- NO manual `.object.get(...)` chains or ad-hoc `std.json.Value` construction for ACP/CLI payloads.
- `std.json.Value` is only acceptable for raw passthrough fields (`rawInput`, `rawOutput`, `_meta`).
- Use `std.json.parseFromValue` and `writer.writeTypedResponse` / `writer.writeTypedNotification`.
- If a web search changes or clarifies ACP/CLI schema, update local docs (`docs/*.md`) in the same change.

## String Matching (Mandatory)

- Any 2+ literal comparisons with `mem.eql`, `mem.indexOf`, or `mem.startsWith` must use a `StaticStringMap` or a loop over a pattern list.
- Command dispatch must be a `StaticStringMap`.
- For symbol/type dispatch, avoid raw string comparisons; map to IDs/enums once and `switch`.

## Comments

- Keep comments minimal.
- No ASCII art separators; for section headers use simple `//` line(s).

## State Machines

- For complex state machines, use a labeled switch with `continue :state`.

## Testing

- Primary: snapshots (ohsnap) + property tests (quickcheck) with a real oracle.
- `std.testing` only for trivial cases, error paths, or when no structured output exists.
- Always run `zig build test` after major changes or adding tests.

## Zed Logs (macOS)

- Zed core + agent/extension host output: `~/Library/Logs/Zed/Zed.log` (and `Zed.log.old`).
- Telemetry: `~/Library/Logs/Zed/telemetry.log`.
- Extension install state: `~/Library/Application Support/Zed/extensions/`.
- External agent bundles: `~/Library/Application Support/Zed/external_agents/`.
- Node extension cache logs (build/tooling): `~/Library/Application Support/Zed/node/cache/_logs/*.log`.
