# Zed Agent Server Extension

## extension.toml Schema

Required fields:

```toml
id = "my-extension"
name = "My Extension"
version = "0.1.0"
schema_version = 1
description = "Brief description"
authors = ["Name <email@example.com>"]
repository = "https://github.com/user/repo"
```

Optional: `license = "MIT"`

## Agent Server Config

```toml
[agent_servers.my-agent]
name = "Display Name"
icon = "icon/agent.svg"  # 16x16 SVG, monochrome

[agent_servers.my-agent.env]
SOME_VAR = "value"  # env vars for all platforms

[agent_servers.my-agent.targets.darwin-aarch64]
archive = "https://github.com/.../agent-darwin-arm64.tar.gz"
cmd = "./agent"
args = ["--flag"]
sha256 = "optional-hash"

[agent_servers.my-agent.targets.darwin-x86_64]
archive = "..."
cmd = "./agent"

[agent_servers.my-agent.targets.linux-x86_64]
archive = "..."
cmd = "./agent"

[agent_servers.my-agent.targets.linux-x86_64.env]
PLATFORM_SPECIFIC = "value"  # platform-specific override
```

## Target Platforms

| Target | OS | Arch |
|--------|-----|------|
| `darwin-aarch64` | macOS | ARM64 (M1/M2) |
| `darwin-x86_64` | macOS | Intel |
| `linux-x86_64` | Linux | x64 |
| `windows-x86_64` | Windows | x64 |

## Icon Requirements

- Format: SVG only
- Size: 16x16 bounding box
- Padding: 1-2px recommended
- Color: Auto-converted to monochrome
- Opacity allowed for layering
- Optimize with SVGOMG

## Archive Structure

Binary inside archive must match `cmd` path:
```
archive.tar.gz
└── banjo          # cmd = "./banjo"
```

## User Configuration via settings.json

### Custom Agent Servers (for development)

For local development or custom agents not installed from extensions:

```json
{
  "agent_servers": {
    "banjo": {
      "type": "custom",
      "command": "/path/to/banjo/zig-out/bin/banjo",
      "args": ["--agent"]
    }
  }
}
```

Required fields for custom agents:
- **type** - Must be `"custom"` for non-extension agents
- **command** - Full path to the executable
- **args** - Command-line arguments (optional)
- **env** - Environment variables (optional)

### Configuring Installed Extension Agents

For agents installed from extensions, override settings:

```json
{
  "agent_servers": {
    "banjo": {
      "env": {
        "BANJO_AUTO_RESUME": "false"
      }
    }
  }
}
```

Environment variables in `settings.json` override those in `extension.toml`.

## Testing Locally

1. Cmd+Shift+P → `zed: install dev extension`
2. Select `extension/` (contains `extension.toml`)
3. Agent appears in Agent Panel dropdown

Note: the repo root does not contain a manifest.

## Useful Zed Commands

| Command | Action |
|---------|--------|
| `workspace: reload` | Restart Zed, picks up new settings |
| `editor: restart language server` | Restart LSP for current file |
| `editor: reload file` | Reload file from disk |
| `zed: open local settings` | Open `.zed/settings.json` |
| `zed: open settings` | Open global settings |
| `theme selector: reload` | Reload themes from disk |
| `context server: restart` | Restart context server |

## Publishing to Zed Extension Registry

### Prerequisites

1. **License required** (as of Oct 1, 2025): MIT, Apache 2.0, BSD 3-Clause, or GPLv3
   - File must be at repo root with `LICENSE` or `LICENCE` prefix
   - CI will fail without valid license

2. **Build release binaries** for all targets:
   - `darwin-aarch64` (macOS ARM64)
   - `darwin-x86_64` (macOS Intel)
   - `linux-x86_64` (Linux x64)
   - `windows-x86_64` (Windows x64) - optional

3. **Create GitHub release** with archives (.tar.gz)
   - Include SHA-256 hashes: `shasum -a 256 archive.tar.gz`

4. **Update extension.toml** with archive URLs and hashes

### Submit PR to zed-industries/extensions

```bash
# Fork and clone zed-industries/extensions
git clone https://github.com/YOUR_USERNAME/extensions.git
cd extensions

# Add your extension as submodule (HTTPS, not SSH!)
git submodule add https://github.com/joelreymont/banjo.git extensions/banjo

# Add entry to extensions.toml
cat >> extensions.toml << 'EOF'
[banjo]
submodule = "extensions/banjo"
version = "0.1.0"
EOF

# Sort files (required)
pnpm sort-extensions

# Commit and push
git add .
git commit -m "Add banjo extension"
git push origin main

# Open PR to zed-industries/extensions
```

### Naming Rules

- Extension ID and name must NOT contain "zed" or "Zed"
- Fork to personal account (not org) so Zed staff can push fixes

### Updating Published Extension

```bash
cd extensions
git submodule update --remote extensions/banjo
# Update version in extensions.toml
pnpm sort-extensions
git commit -am "Update banjo to v0.1.1"
```

## CI for Release Builds

For cross-platform builds, use GitHub Actions:

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: macos-latest
            target: aarch64-macos
            artifact: banjo-darwin-arm64.tar.gz
          - os: macos-13
            target: x86_64-macos
            artifact: banjo-darwin-x64.tar.gz
          - os: ubuntu-latest
            target: x86_64-linux
            artifact: banjo-linux-x64.tar.gz
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.0
      - run: zig build -Doptimize=.ReleaseSafe -Dtarget=${{ matrix.target }}
      - run: tar -czf ${{ matrix.artifact }} -C zig-out/bin banjo
      - uses: softprops/action-gh-release@v1
        with:
          files: ${{ matrix.artifact }}
```

## Language Server Config (WASM Extension Required)

**IMPORTANT**: Unlike agent servers, language servers require WASM extension code.

Just adding `[language_servers.x]` to extension.toml does NOT work. You must:

1. Create WASM that implements `language_server_command()`
2. Place as `extension.wasm` in extension directory
3. **Do NOT add `[lib]` section** - Zed auto-detects extension.wasm

### How Zed Handles WASM (from source analysis)

```
extension_builder.rs:564-567:
  if Cargo.toml exists → set lib.kind = Rust → compile

extension_builder.rs:94-100:
  if lib.kind == Some(Rust) → compile_rust_extension()

extension_host.rs:1637-1642:
  if extension.wasm exists → auto-set lib.kind for loading
```

**For pre-built WASM (dev or published):**
- Do NOT have `Cargo.toml` in extension directory
- Do NOT add `[lib]` section to extension.toml
- Just place `extension.wasm` in extension root
- Zed auto-detects and loads it

### WASM Options

**Option 1: Rust (official)**
- Use `zed_extension_api` crate
- Compile with `cargo build --target wasm32-wasip2`
- ~20 lines of code

**Option 2: Pure Zig (no libc)**
- Use `wasm32-freestanding` target
- Implement Canonical ABI manually
- Use `wasm-tools component embed` + `wasm-tools component new`
- Much smaller output (~500KB vs ~5MB Rust)

### API Version Selection (CRITICAL)

Each API version requires different exports. Use the OLDEST version that has the features you need:

| Version | Required Exports |
|---------|------------------|
| 0.0.1   | `init-extension`, `language-server-command`, `language-server-initialization-options` |
| 0.1.0+  | Adds slash commands: `complete-slash-command-argument`, `run-slash-command` |
| 0.8.0   | ~20 exports including debug adapters, context servers, docs providers |

**For LSP-only extensions, use v0.0.1** - it only requires 3 exports.

The version is embedded as a custom WASM section `zed:api-version` containing 6 bytes:
`[major_hi, major_lo, minor_hi, minor_lo, patch_hi, patch_lo]` (big-endian u16 triplet)

### Canonical ABI

Key points:
- **Strings**: `(ptr: i32, len: i32)` pair
- **Lists**: Same as strings - ptr to array + length
- **Records**: Flattened into scalar params
- **Results**: i32 discriminant (0=ok, 1=err) + payload
- **Resources**: i32 handle
- **cabi_realloc**: Must export `(old_ptr, old_size, align, new_size) -> ptr`
- **Export names**: Use quoted identifiers for hyphens: `export fn @"init-extension"()`

### Build Steps

```bash
# 1. Compile Zig to core WASM
zig build

# 2. Embed WIT metadata (use wit from zed/crates/extension_api/wit/since_v0.0.1/)
wasm-tools component embed --world extension wit/ zig-out/bin/extension.wasm -o embedded.wasm

# 3. Create component
wasm-tools component new embedded.wasm -o component.wasm

# 4. Add zed:api-version section (see tools/add_version_section.zig)
add-version-section component.wasm extension.wasm
```

See: https://component-model.bytecodealliance.org/advanced/canonical-abi.html

### Secondary Language Servers Limitation

**CRITICAL**: Extensions cannot auto-register secondary language servers for languages that already have a primary LSP.

For example, if you create an extension with:
```toml
[language_servers.my-lsp]
languages = ["Zig"]
```

And Zig already uses `zls` as primary LSP, your extension's LSP will NOT auto-start. Users must explicitly enable it in their `settings.json`:

```json
{
  "languages": {
    "Zig": { "language_servers": ["zls", "my-lsp"] }
  }
}
```

The `languages` field in extension.toml declares which languages your LSP **supports**, but does NOT auto-enable it alongside existing LSPs.

See: https://github.com/zed-industries/zed/issues/15279

### Solution: /setup Command

Banjo provides a `/setup` command in the agent panel that automatically:
1. Scans project for source files
2. Detects languages (Zig, Rust, Python, etc.)
3. Creates `.zed/settings.json` with banjo-notes as secondary LSP
4. Includes the binary path for the LSP

Usage: Type `/setup` in the Banjo agent panel. This creates project-local settings that work alongside global Zed config.

### Example extension structure:

```
my-extension/
  extension.toml      # metadata + agent_servers
  Cargo.toml          # Rust deps
  src/lib.rs          # implements Extension trait
```

### src/lib.rs:

```rust
use zed_extension_api::{self as zed, LanguageServerId, Result};

struct MyExtension;

impl zed::Extension for MyExtension {
    fn new() -> Self { Self }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        Ok(zed::Command {
            command: "./banjo".to_string(),
            args: vec!["--lsp".to_string()],
            env: Default::default(),
        })
    }
}

zed::register_extension!(MyExtension);
```

### extension.toml (with language server):

```toml
id = "my-extension"
name = "My Extension"
version = "0.1.0"
schema_version = 1

[lib]
kind = "Rust"
version = "0.7.0"

[language_servers.my-lsp]
name = "My LSP"
languages = ["Zig", "Rust", "Python"]  # must match Zed language names
```

The `languages` field must match names from Zed's built-in language configs.

### Alternative: User settings.json

For development without Rust extension:

```json
{
  "lsp": {
    "banjo-notes": {
      "binary": { "path": "/path/to/banjo", "arguments": ["--lsp"] }
    }
  },
  "languages": {
    "Zig": { "language_servers": ["zls", "banjo-notes"] },
    "Rust": { "language_servers": ["rust-analyzer", "banjo-notes"] }
  }
}
```

## Reference

- https://zed.dev/docs/extensions/agent-servers
- https://zed.dev/docs/extensions/languages
- https://zed.dev/docs/extensions/developing-extensions
- https://github.com/zed-industries/extensions
