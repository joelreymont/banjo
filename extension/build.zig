const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Pure Zig WASM module - freestanding (no libc, no WASI)
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize = optimize,
    });

    const wasm = b.addExecutable(.{
        .name = "extension",
        .root_module = wasm_mod,
    });

    wasm.entry = .disabled;
    wasm.export_memory = true;
    wasm.rdynamic = true;

    b.installArtifact(wasm);

    // Step 1: Embed WIT metadata into core wasm
    const embed = b.addSystemCommand(&.{
        "wasm-tools",
        "component",
        "embed",
        "--world",
        "extension",
    });
    embed.addDirectoryArg(b.path("wit"));
    embed.addArtifactArg(wasm);
    embed.addArgs(&.{"-o"});
    const embedded_wasm = embed.addOutputFileArg("extension.embedded.wasm");

    // Step 2: Convert to component
    const compose = b.addSystemCommand(&.{
        "wasm-tools",
        "component",
        "new",
    });
    compose.addFileArg(embedded_wasm);
    compose.addArgs(&.{"-o"});
    const component_wasm = compose.addOutputFileArg("extension.component.wasm");

    // Step 3: Add zed:api-version custom section
    const add_version = b.addRunArtifact(b.addExecutable(.{
        .name = "add-version-section",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/add_version_section.zig"),
            .target = b.graph.host,
        }),
    }));
    add_version.addFileArg(component_wasm);
    const final_wasm = add_version.addOutputFileArg("extension.wasm");

    // Install final wasm to extension root
    const install = b.addInstallFile(final_wasm, "../extension.wasm");

    const compose_step = b.step("component", "Build WASM component");
    compose_step.dependOn(&install.step);
}
