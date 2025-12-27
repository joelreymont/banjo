# Testing Philosophy - MANDATORY

**Snapshot tests (ohsnap) and property tests (quickcheck) are the PRIMARY testing tools.**

`std.testing.*` assertions are a LAST RESORT.

## Why

1. **Snapshot tests (ohsnap)**: Compare entire data structures, JSON output. When the structure changes, the diff shows exactly what changed.

2. **Property tests (quickcheck)**: Test invariants across random inputs. Roundtrips, transformations, idempotence.

## Property Tests Require Oracles

A property test without an oracle is useless. Always have a reference implementation:

```zig
// BAD - no oracle, just checking enum is valid
fn prop(args: struct { kind: SymbolKind }) bool {
    return kind != .unknown; // meaningless
}

// GOOD - oracle provides ground truth
fn prop(args: struct { content: [64]u8 }) bool {
    const hash1 = computeHash(&args.content);
    const hash2 = oracleHash(&args.content); // reference implementation
    return hash1 == hash2;
}
```

## Only use std.testing when:

1. Testing a single trivial function with 1-2 inputs
2. Testing error conditions
3. No structured output to compare
