# AGENTS.md - Guidelines for AI Agents

## Project Overview

**zcheck** is a property-based testing library for Zig. It generates random test inputs and automatically shrinks failing cases to minimal counterexamples.

## Architecture

```
src/
  zcheck.zig     # Main library - generators, shrinking, check() API
  version.zig    # Version info (build-time injected)
  example.zig    # Usage examples
```

### Core Components

1. **`check()`** - Main entry point. Takes a property function and config, runs iterations.
2. **`generate()`** - Type-driven random value generation. Handles integers, floats, bools, enums, optionals, arrays, structs, tagged unions, String, Id, FilePath, BoundedSlice.
3. **`shrinkOnce()`** / **`shrinkLoop()`** - Shrinking logic to find minimal counterexamples (including enums/unions).
4. **Bounded types** - `String`, `Id`, `FilePath`, `BoundedSlice` for allocation-free testing.
5. **Constrained generators** - `intRange()`, `bytes()` for controlled generation.

## Key Design Decisions

- **Comptime type inspection**: Uses `@typeInfo` to generate values for arbitrary types
- **No allocator needed**: Fixed-size types only, bounded strings with stack buffers
- **Boundary value bias**: 20% chance of generating edge cases (0, 1, max, min)
- **Shrinking strategy**: Binary search toward zero for numbers, null for optionals, empty for strings

## Contribution Guidelines

### Adding New Generators

To support a new type:

1. Add case to `generate()` switch
2. Add corresponding shrink case to `shrinkOnce()`
3. Add tests for both generation and shrinking

### Test Coverage Requirements

- Every generator must have a generation test
- Every shrink strategy must have a shrink test
- Property tests should use `.seed` for reproducibility in CI

### Code Style

- Follow Zig stdlib conventions
- Use `comptime` parameters for type-level operations
- Prefer inline switch/if for type dispatch
- Document public functions with `///` doc comments

## Common Tasks

### Run Tests
```bash
zig build test
```

### Run Example
```bash
zig build example
```

## Docs

- `docs/zig-0.15-io-api.md` - Zig 0.15 IO API changes reference.

## Known Limitations

- Cannot generate slices (use String, Id, FilePath, or BoundedSlice instead)
- Cannot generate pointers
- Untagged unions are not supported

## Future Enhancements (if needed)

- Allocator-backed generators for dynamic types
- Stateful property testing
- Coverage-guided generation
- Custom shrink strategies via user callbacks
