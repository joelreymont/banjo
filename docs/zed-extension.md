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

## Testing Locally

1. Cmd+Shift+P → `zed: install dev extension`
2. Select extension directory (contains `extension.toml`)
3. Agent appears in Agent Panel dropdown

## Publishing

1. Build release binaries for all targets
2. Create GitHub release with archives
3. Submit to [zed-industries/extensions](https://github.com/zed-industries/extensions)

## Reference

- https://zed.dev/docs/extensions/agent-servers
- https://zed.dev/docs/extensions/developing-extensions
