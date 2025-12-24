//! Minimal property-based testing library.
//!
//! Provides typed generators with shrinking for finding minimal counterexamples.
//! Inspired by QuickCheck/Hypothesis but tailored for dixie's needs.
//!
//! Usage:
//! ```zig
//! test "addition is commutative" {
//!     try quickcheck.check(struct {
//!         fn property(args: struct { a: i32, b: i32 }) bool {
//!             return args.a + args.b == args.b + args.a;
//!         }
//!     }.property, .{});
//! }
//! ```

const std = @import("std");
const testing = std.testing;

/// Configuration for property tests.
pub const Config = struct {
    /// Number of random test cases to generate.
    iterations: usize = 100,
    /// Random seed (0 = use timestamp).
    seed: u64 = 0,
    /// Maximum shrink attempts per failure.
    max_shrinks: usize = 100,
    /// If true, test passes when property fails (for testing shrinking).
    expect_failure: bool = false,
};

/// Run a property test with the given property function.
/// The property function takes a struct of generated values and returns bool.
/// Returns error if a counterexample is found.
pub fn check(comptime property: anytype, config: Config) !void {
    const Args = @typeInfo(@TypeOf(property)).@"fn".params[0].type.?;
    try checkType(Args, property, config);
}

fn checkType(comptime Args: type, comptime property: anytype, config: Config) !void {
    const seed = if (config.seed == 0) blk: {
        break :blk @as(u64, @intCast(std.time.timestamp()));
    } else config.seed;

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        const args = generate(Args, random);

        if (!property(args)) {
            // Found counterexample, try to shrink it
            const shrunk = shrinkLoop(Args, property, args, config.max_shrinks);

            if (config.expect_failure) {
                // Test is verifying that shrinking works - success!
                return;
            }

            std.debug.print("\n=== Property failed ===\n", .{});
            std.debug.print("Seed: {}\n", .{seed});
            std.debug.print("Iteration: {}\n", .{i});
            std.debug.print("Original: {any}\n", .{args});
            std.debug.print("Shrunk:   {any}\n", .{shrunk});

            return error.PropertyFailed;
        }
    }

    // If we expected a failure but property always passed, that's an error
    if (config.expect_failure) {
        return error.ExpectedFailure;
    }
}

/// Generate a random value of type T.
pub fn generate(comptime T: type, random: std.Random) T {
    return switch (@typeInfo(T)) {
        .int => generateInt(T, random),
        .float => generateFloat(T, random),
        .bool => random.boolean(),
        .@"enum" => generateEnum(T, random),
        .optional => |opt| if (random.boolean()) generate(opt.child, random) else null,
        .array => |arr| generateArray(arr.child, arr.len, random),
        .@"struct" => |s| generateStruct(T, s, random),
        .pointer => |ptr| switch (ptr.size) {
            .slice => @panic("Cannot generate slices (need allocator)"),
            else => @panic("Cannot generate pointers"),
        },
        else => @compileError("Cannot generate type: " ++ @typeName(T)),
    };
}

fn generateInt(comptime T: type, random: std.Random) T {
    // 20% chance of boundary values
    if (random.uintLessThan(u8, 5) == 0) {
        const boundaries = [_]T{
            0,
            1,
            std.math.maxInt(T),
            if (@typeInfo(T).int.signedness == .signed) std.math.minInt(T) else 0,
            if (@typeInfo(T).int.signedness == .signed) -1 else std.math.maxInt(T),
        };
        return boundaries[random.uintLessThan(usize, boundaries.len)];
    }
    return random.int(T);
}

fn generateFloat(comptime T: type, random: std.Random) T {
    // 20% chance of special values
    if (random.uintLessThan(u8, 5) == 0) {
        const specials = [_]T{ 0.0, 1.0, -1.0, std.math.floatMin(T), std.math.floatMax(T) };
        return specials[random.uintLessThan(usize, specials.len)];
    }
    return @as(T, @floatFromInt(random.int(i32))) / 1000.0;
}

fn generateEnum(comptime T: type, random: std.Random) T {
    const fields = @typeInfo(T).@"enum".fields;
    const idx = random.uintLessThan(usize, fields.len);
    return @enumFromInt(fields[idx].value);
}

fn generateArray(comptime Child: type, comptime len: usize, random: std.Random) [len]Child {
    var result: [len]Child = undefined;
    for (&result) |*elem| {
        elem.* = generate(Child, random);
    }
    return result;
}

fn generateStruct(comptime T: type, comptime s: std.builtin.Type.Struct, random: std.Random) T {
    var result: T = undefined;
    inline for (s.fields) |field| {
        @field(result, field.name) = generate(field.type, random);
    }
    return result;
}

/// Shrink a value toward a simpler form that still fails the property.
fn shrinkLoop(comptime T: type, comptime property: anytype, initial: T, max_attempts: usize) T {
    var current = initial;
    var attempts: usize = 0;

    while (attempts < max_attempts) {
        if (shrinkOnce(T, current)) |simpler| {
            if (!property(simpler)) {
                current = simpler;
                attempts = 0; // Reset on progress
                continue;
            }
        }
        attempts += 1;

        // Try shrinking each field independently for structs
        if (@typeInfo(T) == .@"struct") {
            if (shrinkStructField(T, current, property)) |simpler| {
                current = simpler;
                attempts = 0;
                continue;
            }
        }

        break;
    }

    return current;
}

/// Try to shrink a value one step.
fn shrinkOnce(comptime T: type, value: T) ?T {
    return switch (@typeInfo(T)) {
        .int => shrinkInt(T, value),
        .float => shrinkFloat(T, value),
        .bool => if (value) false else null,
        .optional => if (value != null) @as(T, null) else null,
        .array => |arr| shrinkArray(arr.child, arr.len, value),
        .@"struct" => |s| shrinkStruct(T, s, value),
        .@"enum" => null, // Can't shrink enums meaningfully
        else => null,
    };
}

fn shrinkInt(comptime T: type, value: T) ?T {
    if (value == 0) return null;
    if (value > 0) {
        if (value == 1) return 0;
        return @divTrunc(value, 2);
    }
    // Negative: shrink toward 0
    if (value == -1) return 0;
    return @divTrunc(value, 2);
}

fn shrinkFloat(comptime T: type, value: T) ?T {
    if (value == 0.0) return null;
    if (@abs(value) < 0.001) return 0.0;
    return value / 2.0;
}

fn shrinkArray(comptime Child: type, comptime len: usize, value: [len]Child) ?[len]Child {
    // Try to shrink each element
    var result = value;
    for (&result, 0..) |*elem, i| {
        if (shrinkOnce(Child, value[i])) |simpler| {
            elem.* = simpler;
            return result;
        }
    }
    return null;
}

fn shrinkStruct(comptime T: type, comptime s: std.builtin.Type.Struct, value: T) ?T {
    var result = value;
    inline for (s.fields) |field| {
        const field_val = @field(value, field.name);
        if (shrinkOnce(field.type, field_val)) |simpler| {
            @field(result, field.name) = simpler;
            return result;
        }
    }
    return null;
}

fn shrinkStructField(comptime T: type, value: T, comptime property: anytype) ?T {
    const s = @typeInfo(T).@"struct";
    inline for (s.fields) |field| {
        const field_val = @field(value, field.name);
        if (shrinkOnce(field.type, field_val)) |simpler| {
            var candidate = value;
            @field(candidate, field.name) = simpler;
            if (!property(candidate)) {
                return candidate;
            }
        }
    }
    return null;
}

//
// Convenience generators for constrained values
//

/// Generate an integer in a specific range [min, max].
pub fn intRange(comptime T: type, random: std.Random, min: T, max: T) T {
    std.debug.assert(min <= max);
    if (min == max) return min;

    const range: u64 = @intCast(@as(i128, max) - @as(i128, min) + 1);
    const offset: T = @intCast(random.uintLessThan(u64, range));
    return min + offset;
}

/// Generate an array of random bytes.
pub fn bytes(comptime len: usize, random: std.Random) [len]u8 {
    var result: [len]u8 = undefined;
    random.bytes(&result);
    return result;
}

//
// Tests
//

test "generate integers" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const v = generate(i32, random);
        _ = v;
    }

    for (0..100) |_| {
        const v = generate(u64, random);
        _ = v;
    }
}

test "generate structs" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    const Point = struct { x: i32, y: i32 };
    for (0..100) |_| {
        const p = generate(Point, random);
        _ = p;
    }
}

test "generate arrays" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..100) |_| {
        const arr = generate([4]u8, random);
        _ = arr;
    }
}

test "shrink integers toward zero" {
    try testing.expectEqual(@as(i32, 50), shrinkInt(i32, 100).?);
    try testing.expectEqual(@as(i32, 0), shrinkInt(i32, 1).?);
    try testing.expectEqual(@as(?i32, null), shrinkInt(i32, 0));
    try testing.expectEqual(@as(i32, -50), shrinkInt(i32, -100).?);
    try testing.expectEqual(@as(i32, 0), shrinkInt(i32, -1).?);
}

test "check passes for true property" {
    try check(struct {
        fn prop(_: struct { a: u8, b: u8 }) bool {
            return true;
        }
    }.prop, .{ .iterations = 10 });
}

test "check fails for false property" {
    // Use expect_failure to verify shrinking works without printing noise
    try check(struct {
        fn prop(args: struct { a: u8 }) bool {
            return args.a == 0; // Fails for most values
        }
    }.prop, .{ .iterations = 100, .seed = 12345, .expect_failure = true });
}

test "intRange generates in bounds" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..1000) |_| {
        const v = intRange(i32, random, -100, 100);
        try testing.expect(v >= -100 and v <= 100);
    }
}

test "addition is commutative" {
    try check(struct {
        fn prop(args: struct { a: i16, b: i16 }) bool {
            // Use smaller type to avoid overflow issues in test
            const sum1 = @as(i32, args.a) + @as(i32, args.b);
            const sum2 = @as(i32, args.b) + @as(i32, args.a);
            return sum1 == sum2;
        }
    }.prop, .{});
}
