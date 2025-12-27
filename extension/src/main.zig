// Zed Extension - Pure Zig implementation (freestanding, no libc)
// Implements WASM Component Model Canonical ABI directly
// API version section added by tools/add_version_section.zig

//
// Host Imports - Resource management
//

// Drop a worktree handle (required by Component Model for borrow cleanup)
extern "$root" fn @"[resource-drop]worktree"(handle: i32) void;

//
// Memory Management
//

var heap: [4096]u8 = undefined;
var heap_offset: usize = 0;

fn alignUp(ptr: usize, alignment: usize) usize {
    return (ptr + alignment - 1) & ~(alignment - 1);
}

fn alloc(size: usize, alignment: usize) ?[*]u8 {
    const aligned = alignUp(heap_offset, alignment);
    if (aligned + size > heap.len) return null;
    heap_offset = aligned + size;
    return @ptrCast(&heap[aligned]);
}

// cabi_realloc - Canonical ABI memory allocation
// Called by host to allocate memory for strings/lists passed to exports
export fn cabi_realloc(
    old_ptr: ?[*]u8,
    old_size: usize,
    alignment: usize,
    new_size: usize,
) ?[*]u8 {
    _ = old_ptr;
    _ = old_size;
    if (new_size == 0) return @ptrFromInt(alignment);
    return alloc(new_size, alignment);
}

//
// Static Data
//

const command_str = "./banjo";
const arg_str = "--lsp";

//
// Return Area
//

// Layout for result<command, string>:
//   [0]: i32 discriminant (0=ok, 1=err)
//   [4]: ptr (command.command.ptr or err.ptr)
//   [8]: len (command.command.len or err.len)
//   [12]: args.ptr
//   [16]: args.len
//   [20]: env.ptr
//   [24]: env.len
var ret_area: [28]u8 align(4) = undefined;

// Layout for list<string> element: ptr (4 bytes) + len (4 bytes)
var args_list: [8]u8 align(4) = undefined;

// Layout for result<option<string>, string>:
//   [0]: i32 discriminant (0=ok, 1=err)
//   [4]: option discriminant (0=none, 1=some) or err.ptr
//   [8]: string.ptr or err.len
//   [12]: string.len
var ret_area_init_options: [16]u8 align(4) = undefined;

//
// Exported Functions
//

// init-extension: func()
export fn @"init-extension"() void {}

// language-server-command: func(config: language-server-config, worktree: borrow<worktree>) -> result<command, string>
// Params: (config.name.ptr, config.name.len, config.language_name.ptr, config.language_name.len, worktree_handle)
// Returns: pointer to ret_area
export fn @"language-server-command"(
    _: [*]const u8, // config.name.ptr
    _: usize, // config.name.len
    _: [*]const u8, // config.language_name.ptr
    _: usize, // config.language_name.len
    worktree: i32,
) [*]u8 {
    // Drop the borrowed worktree handle (required by Component Model)
    @"[resource-drop]worktree"(worktree);

    // Reset heap for this call
    heap_offset = 0;

    // Build args list: single element ["--lsp"]
    const args_ptr: *align(1) [*]const u8 = @ptrCast(&args_list[0]);
    const args_len: *align(1) usize = @ptrCast(&args_list[4]);
    args_ptr.* = arg_str.ptr;
    args_len.* = arg_str.len;

    // Write result<command, string> with ok variant
    const discriminant: *align(1) i32 = @ptrCast(&ret_area[0]);
    discriminant.* = 0; // ok

    const cmd_ptr: *align(1) [*]const u8 = @ptrCast(&ret_area[4]);
    const cmd_len: *align(1) usize = @ptrCast(&ret_area[8]);
    cmd_ptr.* = command_str.ptr;
    cmd_len.* = command_str.len;

    const list_args_ptr: *align(1) [*]u8 = @ptrCast(&ret_area[12]);
    const list_args_len: *align(1) usize = @ptrCast(&ret_area[16]);
    list_args_ptr.* = &args_list;
    list_args_len.* = 1;

    const env_ptr: *align(1) ?[*]u8 = @ptrCast(&ret_area[20]);
    const env_len: *align(1) usize = @ptrCast(&ret_area[24]);
    env_ptr.* = null;
    env_len.* = 0;

    return &ret_area;
}

// Post-return cleanup (called by host after processing return value)
export fn @"cabi_post_language-server-command"(_: [*]u8) void {
    // Nothing to free - we use static data
}

// language-server-initialization-options: func(config: language-server-config, worktree: borrow<worktree>) -> result<option<string>, string>
export fn @"language-server-initialization-options"(
    _: [*]const u8, // config.name.ptr
    _: usize, // config.name.len
    _: [*]const u8, // config.language_name.ptr
    _: usize, // config.language_name.len
    worktree: i32,
) [*]u8 {
    // Drop the borrowed worktree handle (required by Component Model)
    @"[resource-drop]worktree"(worktree);

    // Write result<option<string>, string> with ok(none)
    const discriminant: *align(1) i32 = @ptrCast(&ret_area_init_options[0]);
    discriminant.* = 0; // ok

    const option_discriminant: *align(1) i32 = @ptrCast(&ret_area_init_options[4]);
    option_discriminant.* = 0; // none

    return &ret_area_init_options;
}

// Post-return cleanup
export fn @"cabi_post_language-server-initialization-options"(_: [*]u8) void {
    // Nothing to free
}
