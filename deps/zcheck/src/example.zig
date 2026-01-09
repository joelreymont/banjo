const std = @import("std");
const zc = @import("zcheck");

pub fn main() !void {
    std.debug.print("Running zcheck examples...\n\n", .{});

    // Example 1: Testing addition commutativity
    std.debug.print("Testing: addition is commutative\n", .{});
    try zc.check(struct {
        fn prop(args: struct { a: i16, b: i16 }) bool {
            const sum1 = @as(i32, args.a) + @as(i32, args.b);
            const sum2 = @as(i32, args.b) + @as(i32, args.a);
            return sum1 == sum2;
        }
    }.prop, .{ .iterations = 1000 });
    std.debug.print("  PASSED\n\n", .{});

    // Example 2: Testing sort is idempotent
    std.debug.print("Testing: sorting twice equals sorting once\n", .{});
    try zc.check(struct {
        fn prop(args: struct { arr: [8]u8 }) bool {
            var sorted1 = args.arr;
            var sorted2 = args.arr;

            std.mem.sort(u8, &sorted1, {}, std.sort.asc(u8));
            std.mem.sort(u8, &sorted2, {}, std.sort.asc(u8));
            std.mem.sort(u8, &sorted2, {}, std.sort.asc(u8));

            return std.mem.eql(u8, &sorted1, &sorted2);
        }
    }.prop, .{ .iterations = 1000 });
    std.debug.print("  PASSED\n\n", .{});

    // Example 3: Using constrained generators
    std.debug.print("Testing: values in range stay in range after abs\n", .{});
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..1000) |_| {
        const v = zc.intRange(i32, random, -100, 100);
        const abs_v = @abs(v);
        if (abs_v > 100) {
            std.debug.print("  FAILED: {} -> {}\n", .{ v, abs_v });
            return error.TestFailed;
        }
    }
    std.debug.print("  PASSED\n\n", .{});

    std.debug.print("All examples passed!\n", .{});
}
