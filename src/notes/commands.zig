const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const Allocator = mem.Allocator;
const comments = @import("comments.zig");
const lsp_uri = @import("../lsp/uri.zig");

const log = std.log.scoped(.notes);

const NoteList = std.ArrayListUnmanaged(comments.ParsedNote);
const NotesByFile = std.StringHashMap(NoteList);

/// Result of a notes command
pub const CommandResult = struct {
    success: bool,
    message: []const u8,

    pub fn deinit(self: *CommandResult, allocator: Allocator) void {
        allocator.free(self.message);
    }
};

pub const SetupPayload = struct {
    settings_json: []const u8,
    message: []const u8,

    pub fn deinit(self: *SetupPayload, allocator: Allocator) void {
        allocator.free(self.settings_json);
        allocator.free(self.message);
    }
};

/// Map of file extensions to Zed language names and their primary LSP
const LanguageInfo = struct {
    zed_name: []const u8,
    primary_lsp: []const u8,
};

const extension_to_language = std.StaticStringMap(LanguageInfo).initComptime(.{
    .{ ".zig", LanguageInfo{ .zed_name = "Zig", .primary_lsp = "zls" } },
    .{ ".rs", LanguageInfo{ .zed_name = "Rust", .primary_lsp = "rust-analyzer" } },
    .{ ".py", LanguageInfo{ .zed_name = "Python", .primary_lsp = "pyright" } },
    .{ ".js", LanguageInfo{ .zed_name = "JavaScript", .primary_lsp = "typescript-language-server" } },
    .{ ".ts", LanguageInfo{ .zed_name = "TypeScript", .primary_lsp = "typescript-language-server" } },
    .{ ".tsx", LanguageInfo{ .zed_name = "TSX", .primary_lsp = "typescript-language-server" } },
    .{ ".jsx", LanguageInfo{ .zed_name = "JavaScript", .primary_lsp = "typescript-language-server" } },
    .{ ".go", LanguageInfo{ .zed_name = "Go", .primary_lsp = "gopls" } },
    .{ ".c", LanguageInfo{ .zed_name = "C", .primary_lsp = "clangd" } },
    .{ ".cpp", LanguageInfo{ .zed_name = "C++", .primary_lsp = "clangd" } },
    .{ ".cc", LanguageInfo{ .zed_name = "C++", .primary_lsp = "clangd" } },
    .{ ".h", LanguageInfo{ .zed_name = "C", .primary_lsp = "clangd" } },
    .{ ".hpp", LanguageInfo{ .zed_name = "C++", .primary_lsp = "clangd" } },
    .{ ".rb", LanguageInfo{ .zed_name = "Ruby", .primary_lsp = "ruby-lsp" } },
    .{ ".ex", LanguageInfo{ .zed_name = "Elixir", .primary_lsp = "elixir-ls" } },
    .{ ".exs", LanguageInfo{ .zed_name = "Elixir", .primary_lsp = "elixir-ls" } },
    .{ ".md", LanguageInfo{ .zed_name = "Markdown", .primary_lsp = "" } },
});

/// Directories to skip when scanning for source files
const skip_dirs = std.StaticStringMap(void).initComptime(.{
    .{ "node_modules", {} },
    .{ "target", {} },
    .{ "zig-out", {} },
    .{ "zig-cache", {} },
    .{ ".zig-cache", {} },
    .{ "dist", {} },
    .{ "build", {} },
    .{ "vendor", {} },
    .{ "__pycache__", {} },
});

const max_scan_depth: usize = 64;

const CommandHandler = *const fn (Allocator, []const u8, []const u8) anyerror!CommandResult;

const command_handlers = std.StaticStringMap(CommandHandler).initComptime(.{
    .{ "/setup", handleSetup },
    .{ "/notes", handleNotes },
    .{ "/note", handleNote },
});

fn makeResult(allocator: Allocator, success: bool, message: []const u8) !CommandResult {
    const copy = try allocator.dupe(u8, message);
    return .{ .success = success, .message = copy };
}

/// Parse and execute a /note or /notes command
/// Note: With comment-based notes, most operations are done via LSP code actions.
/// Agent panel commands are for listing and searching only.
pub fn executeCommand(allocator: Allocator, project_root: []const u8, command: []const u8) !CommandResult {
    // Extract command name (first word)
    const trimmed = mem.trimLeft(u8, command, " ");
    const space_idx = mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
    const cmd_name = trimmed[0..space_idx];
    const args = if (space_idx < trimmed.len) mem.trimLeft(u8, trimmed[space_idx..], " ") else "";

    if (command_handlers.get(cmd_name)) |handler| {
        return handler(allocator, project_root, args);
    }

    return makeResult(allocator, false, "Unknown command. Try /setup, /notes, or /note");
}

fn handleSetup(allocator: Allocator, project_root: []const u8, _: []const u8) !CommandResult {
    return setupLsp(allocator, project_root);
}

fn handleNotes(allocator: Allocator, project_root: []const u8, _: []const u8) !CommandResult {
    return listNotes(allocator, project_root);
}

const note_subcommands = std.StaticStringMap([]const u8).initComptime(.{
    .{ "create", "To create a note:\n1. Write a comment in your code: // TODO: fix this\n2. Place cursor on that line\n3. Press Cmd+. and select 'Create Banjo Note'\n\nThe comment will be converted to: // @banjo[id] TODO: fix this" },
});

fn handleNote(allocator: Allocator, _: []const u8, args: []const u8) !CommandResult {
    const subcmd = if (mem.indexOf(u8, args, " ")) |idx| args[0..idx] else args;
    if (note_subcommands.get(subcmd)) |msg| {
        return makeResult(allocator, true, msg);
    }
    return makeResult(
        allocator,
        false,
        "Usage: /notes - list notes\n/note create - create a note (use code action instead)",
    );
}

/// List all notes in project grouped by file
fn listNotes(allocator: Allocator, project_root: []const u8) !CommandResult {
    var notes_by_file = NotesByFile.init(allocator);
    defer {
        var it = notes_by_file.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |note| {
                allocator.free(note.id);
                allocator.free(note.content);
                for (note.links) |link| allocator.free(link);
                allocator.free(note.links);
            }
            entry.value_ptr.deinit(allocator);
        }
        notes_by_file.deinit();
    }

    // Scan project for notes
    try scanProjectForNotes(allocator, project_root, &notes_by_file, 0);

    if (notes_by_file.count() == 0) {
        return makeResult(
            allocator,
            true,
            "No notes found.\n\nTo create a note:\n1. Write a comment: // TODO: something\n2. Press Cmd+. and select 'Create Banjo Note'",
        );
    }

    // Build output grouped by file
    var output: std.ArrayListUnmanaged(u8) = .empty;
    const writer = output.writer(allocator);

    var total_notes: usize = 0;
    var file_it = notes_by_file.iterator();
    while (file_it.next()) |entry| {
        const file_path = entry.key_ptr.*;
        const file_notes = entry.value_ptr.items;
        total_notes += file_notes.len;

        // Show relative path
        const rel_path = if (mem.startsWith(u8, file_path, project_root))
            file_path[project_root.len + 1 ..]
        else
            file_path;

        try writer.print("\n**{s}** ({d} notes)\n", .{ rel_path, file_notes.len });

        for (file_notes) |note| {
            const summary = if (note.content.len > 50) note.content[0..50] else note.content;
            try writer.print("  L{d}: `{s}` - {s}\n", .{ note.line, note.id, summary });
        }
    }

    try writer.print("\n---\n**Total:** {d} notes in {d} files\n", .{ total_notes, notes_by_file.count() });

    const message = try output.toOwnedSlice(allocator);
    return .{ .success = true, .message = message };
}

/// Scan project recursively for note comments
fn scanProjectForNotes(allocator: Allocator, dir_path: []const u8, notes_by_file: *NotesByFile, depth: usize) !void {
    if (depth > max_scan_depth) return;
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        log.warn("Failed to open notes dir {s}: {}", .{ dir_path, err });
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden and common non-source dirs
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (skip_dirs.has(entry.name)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .sym_link) continue;
        if (entry.kind == .directory) {
            try scanProjectForNotes(allocator, full_path, notes_by_file, depth + 1);
        } else if (entry.kind == .file) {
            // Check if it's a source file we care about
            const ext = std.fs.path.extension(entry.name);
            if (extension_to_language.get(ext) == null) continue;

            // Read and scan file for notes
            const file = fs.openFileAbsolute(full_path, .{}) catch |err| {
                log.warn("Failed to open note file {s}: {}", .{ full_path, err });
                continue;
            };
            defer file.close();

            const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
                log.warn("Failed to read note file {s}: {}", .{ full_path, err });
                continue;
            };
            defer allocator.free(content);

            const notes = comments.scanFileForNotes(allocator, content) catch |err| {
                log.warn("Failed to scan note file {s}: {}", .{ full_path, err });
                continue;
            };
            if (notes.len > 0) {
                const path_copy = try allocator.dupe(u8, full_path);
                var note_list: std.ArrayListUnmanaged(comments.ParsedNote) = .empty;
                try note_list.appendSlice(allocator, notes);
                try notes_by_file.put(path_copy, note_list);
            }
            allocator.free(notes);
        }
    }
}

/// Find banjo binary path
fn findBanjoBinary(allocator: Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;

    // Check dev build first
    const dev_path = try std.fs.path.join(allocator, &.{ home, "Work/banjo/zig-out/bin/banjo" });
    if (fs.accessAbsolute(dev_path, .{})) |_| {
        return dev_path;
    } else |_| {
        allocator.free(dev_path);
    }

    return error.NotFound;
}

/// Scan project for languages and create .zed/settings.json with banjo-notes as secondary LSP
fn setupLsp(allocator: Allocator, project_root: []const u8) !CommandResult {
    // Detect languages in project
    var detected = std.StringHashMap(LanguageInfo).init(allocator);
    defer detected.deinit();

    try scanForLanguages(allocator, project_root, &detected);

    if (detected.count() == 0) {
        return makeResult(allocator, false, "No supported languages found in project.");
    }

    // Find banjo binary
    const banjo_path = findBanjoBinary(allocator) catch {
        return makeResult(allocator, false, "Could not find banjo binary");
    };
    defer allocator.free(banjo_path);

    // Build .zed/settings.json with binary path (WASM extension not working for dev)
    var json: std.ArrayListUnmanaged(u8) = .empty;
    defer json.deinit(allocator);
    const writer = json.writer(allocator);

    try writer.print(
        \\{{
        \\  "lsp": {{
        \\    "banjo-notes": {{
        \\      "binary": {{ "path": "{s}", "arguments": ["--lsp"] }}
        \\    }}
        \\  }},
        \\  "languages": {{
        \\
    , .{banjo_path});

    var first = true;
    var iter = detected.iterator();
    while (iter.next()) |entry| {
        if (!first) try writer.writeAll(",\n");
        first = false;

        const info = entry.value_ptr.*;
        if (info.primary_lsp.len > 0) {
            try writer.print("    \"{s}\": {{ \"language_servers\": [\"{s}\", \"banjo-notes\"] }}", .{ info.zed_name, info.primary_lsp });
        } else {
            try writer.print("    \"{s}\": {{ \"language_servers\": [\"banjo-notes\"] }}", .{info.zed_name});
        }
    }

    try writer.writeAll("\n  }\n}\n"); // close languages and root

    // Create .zed directory if needed
    const zed_dir_path = try std.fs.path.join(allocator, &.{ project_root, ".zed" });
    defer allocator.free(zed_dir_path);

    fs.makeDirAbsolute(zed_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return makeResult(allocator, false, "Failed to create .zed directory"),
    };

    // Write settings.json
    const settings_path = try std.fs.path.join(allocator, &.{ project_root, ".zed", "settings.json" });
    defer allocator.free(settings_path);

    const file = fs.createFileAbsolute(settings_path, .{}) catch {
        return makeResult(allocator, false, "Failed to create .zed/settings.json");
    };
    defer file.close();

    file.writeAll(json.items) catch {
        return makeResult(allocator, false, "Failed to write .zed/settings.json");
    };

    // Build success message
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    const msg_writer = msg.writer(allocator);
    try msg_writer.writeAll("Created .zed/settings.json with banjo-notes enabled for:\n");

    iter = detected.iterator();
    while (iter.next()) |entry| {
        try msg_writer.print("  - {s}\n", .{entry.value_ptr.zed_name});
    }
    try msg_writer.writeAll("\nReload Zed to activate the LSP.");

    const message = try msg.toOwnedSlice(allocator);
    return .{ .success = true, .message = message };
}

/// Recursively scan directory for source files and detect languages
fn scanForLanguages(allocator: Allocator, dir_path: []const u8, detected: *std.StringHashMap(LanguageInfo)) !void {
    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        log.warn("Failed to open language scan dir {s}: {}", .{ dir_path, err });
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip hidden directories and common non-source dirs
        if (entry.name[0] == '.') continue;
        if (skip_dirs.has(entry.name)) continue;

        if (entry.kind == .directory) {
            const subdir = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(subdir);
            try scanForLanguages(allocator, subdir, detected);
        } else if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            if (extension_to_language.get(ext)) |info| {
                try detected.put(info.zed_name, info);
            }
        }
    }
}

/// Parse Zed URL format: [@filename (line:col)](file:///absolute/path#Lline:col)
/// Returns: file_path, line_number, or null if not a valid Zed URL
pub fn parseZedUrl(allocator: Allocator, url: []const u8) ?struct {
    file_path: []const u8,
    line: u32,
    owned: bool,

    pub fn deinit(self: @This(), alloc: Allocator) void {
        if (self.owned) alloc.free(self.file_path);
    }
} {
    // Look for file:// pattern (file:/// = file:// + /path)
    const file_prefix = "file://";
    const file_start = mem.indexOf(u8, url, file_prefix) orelse return null;
    const path_start = file_start + file_prefix.len;

    // Find #L which marks the line number
    const hash_idx = mem.indexOf(u8, url[path_start..], "#L") orelse return null;
    const uri_slice = url[file_start..];
    const parsed_path = (lsp_uri.uriToPath(allocator, uri_slice) catch return null) orelse return null;
    errdefer if (parsed_path.owned) allocator.free(parsed_path.path);
    const file_path = parsed_path.path;

    // Parse line number after #L
    const line_start = path_start + hash_idx + 2; // skip "#L"
    var line_end = line_start;
    while (line_end < url.len and url[line_end] >= '0' and url[line_end] <= '9') {
        line_end += 1;
    }

    if (line_end == line_start) return null;

    const line = std.fmt.parseInt(u32, url[line_start..line_end], 10) catch return null;

    return .{ .file_path = file_path, .line = line, .owned = parsed_path.owned };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const ohsnap = @import("ohsnap");

test "parseZedUrl extracts file path and line" {
    const url = "[@main.zig (42:1)](file:///Users/joel/project/src/main.zig#L42:1)";
    var result = parseZedUrl(testing.allocator, url);
    defer if (result) |*item| item.deinit(testing.allocator);
    const Summary = struct {
        found: bool,
        file_path: ?[]const u8,
        line: ?u32,
    };
    const summary: Summary = if (result) |item| .{
        .found = true,
        .file_path = item.file_path,
        .line = item.line,
    } else .{
        .found = false,
        .file_path = null,
        .line = null,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.commands.test.parseZedUrl extracts file path and line.Summary
        \\  .found: bool = true
        \\  .file_path: ?[]const u8
        \\    "/Users/joel/project/src/main.zig"
        \\  .line: ?u32
        \\    42
    ).expectEqual(summary);
}

test "parseZedUrl handles line without column" {
    const url = "file:///path/to/file.zig#L100";
    var result = parseZedUrl(testing.allocator, url);
    defer if (result) |*item| item.deinit(testing.allocator);
    const Summary = struct {
        found: bool,
        file_path: ?[]const u8,
        line: ?u32,
    };
    const summary: Summary = if (result) |item| .{
        .found = true,
        .file_path = item.file_path,
        .line = item.line,
    } else .{
        .found = false,
        .file_path = null,
        .line = null,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.commands.test.parseZedUrl handles line without column.Summary
        \\  .found: bool = true
        \\  .file_path: ?[]const u8
        \\    "/path/to/file.zig"
        \\  .line: ?u32
        \\    100
    ).expectEqual(summary);
}

test "parseZedUrl returns null for invalid format" {
    const summary = .{
        .not_url = parseZedUrl(testing.allocator, "not a url") == null,
        .missing_line = parseZedUrl(testing.allocator, "file:///path/no-line") == null,
        .wrong_scheme = parseZedUrl(testing.allocator, "https://example.com#L1") == null,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.commands.test.parseZedUrl returns null for invalid format__struct_<^\d+$>
        \\  .not_url: bool = true
        \\  .missing_line: bool = true
        \\  .wrong_scheme: bool = true
    ).expectEqual(summary);
}

test "setup creates .zed/settings.json with detected languages" {
    const allocator = testing.allocator;

    // Create temp directory with test files
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test source files
    try tmp_dir.dir.writeFile(.{ .sub_path = "main.zig", .data = "fn main() {}" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "test.py", .data = "print('hello')" });

    // Get absolute path
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Run /setup command
    var result = try executeCommand(allocator, tmp_path, "/setup");
    defer result.deinit(allocator);

    // Verify .zed/settings.json was created
    const settings = try tmp_dir.dir.openFile(".zed/settings.json", .{});
    defer settings.close();

    var buf: [4096]u8 = undefined;
    const len = try settings.readAll(&buf);
    const content = buf[0..len];
    const summary = .{
        .success = result.success,
        .message = result.message,
        .settings = content,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.commands.test.setup creates .zed/settings.json with detected languages__struct_<^\d+$>
        \\  .success: bool = true
        \\  .message: []const u8
        \\    "Created .zed/settings.json with banjo-notes enabled for:
        \\  - Zig
        \\  - Python
        \\
        \\Reload Zed to activate the LSP."
        \\  .settings: []u8
        \\    "{
        \\  "lsp": {
        \\    "banjo-notes": {
        \\      "binary": { "path": "/Users/joel/Work/banjo/zig-out/bin/banjo", "arguments": ["--lsp"] }
        \\    }
        \\  },
        \\  "languages": {
        \\    "Zig": { "language_servers": ["zls", "banjo-notes"] },
        \\    "Python": { "language_servers": ["pyright", "banjo-notes"] }
        \\  }
        \\}
        \\"
    ).expectEqual(summary);
}

test "setup returns error for empty project" {
    const allocator = testing.allocator;

    // Create empty temp directory
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Run /setup command
    var result = try executeCommand(allocator, tmp_path, "/setup");
    defer result.deinit(allocator);

    const summary = .{
        .success = result.success,
        .message = result.message,
    };
    try (ohsnap{}).snap(@src(),
        \\notes.commands.test.setup returns error for empty project__struct_<^\d+$>
        \\  .success: bool = false
        \\  .message: []const u8
        \\    "No supported languages found in project."
    ).expectEqual(summary);
}
