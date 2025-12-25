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

Users can configure installed agent extensions in their Zed `settings.json`:

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

Configuration options:
- **env** - Environment variables passed to the agent process
- **command** - Override the executable path (for custom agents)
- **args** - Override command-line arguments

Environment variables defined in `settings.json` override those in `extension.toml`.

## Testing Locally

1. Cmd+Shift+P → `zed: install dev extension`
2. Select extension directory (contains `extension.toml`)
3. Agent appears in Agent Panel dropdown

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

## Reference

- https://zed.dev/docs/extensions/agent-servers
- https://zed.dev/docs/extensions/developing-extensions
- https://github.com/zed-industries/extensions
