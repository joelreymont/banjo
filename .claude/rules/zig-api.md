# Zig 0.15 API Rules

## Convention: Allocator First
**Allocator is ALWAYS the first argument** (after self, if present), following Zig stdlib convention:
```zig
// RIGHT:
pub fn init(alloc: Allocator, buffer: []const u8) Self { ... }
pub fn append(self: *Self, alloc: Allocator, item: T) !void { ... }

// WRONG:
pub fn init(buffer: []const u8, alloc: Allocator) Self { ... }
```

## Arena Allocator Naming
When a function **requires** an arena allocator (allocations outlive the call), name the parameter `arena`:
```zig
pub fn buildTree(arena: Allocator, patterns: []const Pattern) !Tree { ... }
pub fn parse(alloc: Allocator, input: []const u8) !Ast { ... }
```

## Key Gotchas
1. `std.ArrayList(T)` is UNMANAGED - pass allocator to ALL methods
2. `std.StringHashMap` is still managed (uses .init(allocator))
3. No `std.io.getStdOut()` - use `std.io.getStdOut().writer()`
4. No `.init(allocator)` for ArrayList - use `{}` or `.{}`

## Comptime for Performance
Use `comptime` aggressively:
- **Lookup tables**: StaticStringMap for string->value mappings
- **Type generation**: Build specialized types with comptime functions
- **Dead branch elimination**: Use comptime params to eliminate runtime checks
- **Inline hot paths**: `inline fn` for hot paths

## Before Committing
**Always run `zig fmt src/` before committing.**
