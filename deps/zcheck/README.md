# zcheck

A property-based testing library for Zig, inspired by Haskell's QuickCheck and Python's Hypothesis.

## Features

- **Typed generators** for integers, floats, booleans, enums, optionals, arrays, and structs
- **Bounded string types** (String, Id, FilePath) - no allocation needed
- **Bounded generic slices** with `BoundedSlice(T, N)`
- **Automatic shrinking** to find minimal counterexamples
- **Reproducible failures** via configurable seeds
- **Structured failure reporting** via `checkResult`

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zcheck = .{
        .url = "https://github.com/joelreymont/zcheck/archive/refs/heads/main.tar.gz",
        .hash = "...", // Update after first fetch
    },
},
```

Then in `build.zig`:

```zig
const zcheck = b.dependency("zcheck", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zcheck", zcheck.module("zcheck"));
```

## Quick Start

```zig
const std = @import("std");
const zc = @import("zcheck");

test "addition is commutative" {
    try zc.check(struct {
        fn prop(args: struct { a: i32, b: i32 }) bool {
            return args.a + args.b == args.b + args.a;
        }
    }.prop, .{});
}

test "string property" {
    try zc.check(struct {
        fn prop(args: struct { s: zc.String }) bool {
            const str = args.s.slice();
            return str.len <= zc.MAX_STRING_LEN;
        }
    }.prop, .{});
}

test "sort is idempotent" {
    try zc.check(struct {
        fn prop(args: struct { arr: [8]u8 }) bool {
            var sorted1 = args.arr;
            var sorted2 = args.arr;

            std.mem.sort(u8, &sorted1, {}, std.sort.asc(u8));
            std.mem.sort(u8, &sorted2, {}, std.sort.asc(u8));
            std.mem.sort(u8, &sorted2, {}, std.sort.asc(u8));

            return std.mem.eql(u8, &sorted1, &sorted2);
        }
    }.prop, .{});
}
```

## Supported Types

| Type | Generator Behavior |
|------|-------------------|
| `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64` | Random values with 20% boundary cases (0, 1, min, max, -1) |
| `f16`, `f32`, `f64` | Random values with 20% special cases (0, 1, -1, min, max) |
| `bool` | Uniform random |
| `enum` | Uniform random over variants |
| `union(enum)` | Uniform random over variants (tagged unions only) |
| `?T` | 50% null, 50% generated value |
| `[N]T` | Array with each element generated |
| `struct` | Each field generated independently |
| `String` | Bounded printable ASCII (64 bytes max), 10% empty |
| `Id` | Bounded alphanumeric ID (8-36 chars) |
| `FilePath` | Bounded file path with extension (128 bytes max) |
| `BoundedSlice(T, N)` | Bounded slice with generated elements |

## Configuration

```zig
try zc.check(myProperty, .{
    .iterations = 1000,      // Number of test cases (default: 100)
    .seed = 12345,           // Fixed seed for reproducibility (default: timestamp)
    .max_shrinks = 200,      // Maximum shrink attempts (default: 100)
    .expect_failure = false, // Pass if property fails (for testing shrinking)
    .print_failures = true,  // Print counterexample details on failure
    .use_default_values = true, // Respect struct field defaults
    .random = null,          // Optional external RNG (e.g., prng.random())
});
```

## Failure Details

```zig
if (zc.checkResult(myProperty, .{ .seed = 12345 })) |failure| {
    std.debug.print("Seed: {}\\n", .{failure.seed});
    std.debug.print("Original: {any}\\n", .{failure.original});
    std.debug.print("Shrunk:   {any}\\n", .{failure.shrunk});
}
```

## Shrinking

When a counterexample is found, zcheck automatically shrinks it toward a minimal failing case:

- **Integers**: Shrink toward 0 by halving
- **Floats**: Shrink toward 0.0 by halving
- **Booleans**: `true` shrinks to `false`
- **Optionals**: `some(x)` shrinks to `null`
- **Arrays**: Elements shrink individually
- **Structs**: Fields shrink individually
- **Enums**: Shrink toward earlier declaration order
- **Tagged unions**: Shrink active payload, then earlier tags
- **String**: Shrinks toward empty by halving length
- **Id**: Shrinks toward minimum length (8 chars)
- **FilePath**: Shrinks name length while preserving extension
- **BoundedSlice**: Shrinks length and elements

Example output:
```
=== Property failed ===
Seed: 1704067200
Iteration: 42
Original: { .x = 12847, .y = -9823 }
Shrunk:   { .x = 1, .y = 0 }
```

## Constrained Generators

For more control over generated values:

```zig
var prng = std.Random.DefaultPrng.init(seed);
const random = prng.random();

// Integer in range [min, max]
const v = zc.intRange(i32, random, -100, 100);

// Random bytes
const b = zc.bytes(16, random);

// Create String from slice
const s = zc.String.fromSlice("hello");

// Create bounded slice from slice
const Bytes = zc.BoundedSlice(u8, 16);
const bs = Bytes.fromSlice("hello");
```

## Running Tests

```bash
# Run library tests
zig build test

# Run example
zig build example
```

## License

MIT License - see [LICENSE](LICENSE) for details.
