const std = @import("std");

// Zed API version 0.0.1 as big-endian u16 triplet
const VERSION_BYTES = [6]u8{ 0, 0, 0, 0, 0, 1 };
const SECTION_NAME = "zed:api-version";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 3) {
        std.debug.print("Usage: add-version-section <input.wasm> <output.wasm>\n", .{});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    // Read input WASM
    const input = try std.fs.cwd().readFileAlloc(alloc, input_path, 100 * 1024 * 1024);

    // Build custom section
    var section: std.ArrayList(u8) = .{};
    try section.append(alloc, 0); // Custom section ID

    // Section content: name_len + name + content
    const name_len = leb128Size(SECTION_NAME.len);
    const content_size = name_len + SECTION_NAME.len + VERSION_BYTES.len;

    // Write section size as LEB128
    try writeLeb128(alloc, &section, content_size);

    // Write name length as LEB128
    try writeLeb128(alloc, &section, SECTION_NAME.len);

    // Write name
    try section.appendSlice(alloc, SECTION_NAME);

    // Write version bytes
    try section.appendSlice(alloc, &VERSION_BYTES);

    // Write output: original + custom section
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();

    try out_file.writeAll(input);
    try out_file.writeAll(section.items);
}

fn leb128Size(value: usize) usize {
    var v = value;
    var size: usize = 0;
    while (true) {
        size += 1;
        v >>= 7;
        if (v == 0) break;
    }
    return size;
}

fn writeLeb128(alloc: std.mem.Allocator, list: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try list.append(alloc, byte);
            break;
        } else {
            try list.append(alloc, byte | 0x80);
        }
    }
}
