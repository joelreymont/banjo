# Release Skill

Trigger: release, new release, push release, tag release

## Description

Creates a new banjo release by tagging HEAD and pushing to GitHub. CI builds cross-platform binaries automatically.

## Steps

1. **Run tests locally**
   ```bash
   zig build test
   ```

2. **Get current version**
   ```bash
   grep 'version = "' src/acp/agent.zig | head -1
   ```
   Current version: 0.1.0

3. **Delete existing release and tag (if replacing)**
   ```bash
   gh release delete v0.1.0 --yes --cleanup-tag 2>/dev/null || true
   git push origin :refs/tags/v0.1.0 2>/dev/null || true
   git tag -d v0.1.0 2>/dev/null || true
   ```

4. **Create and push tag**
   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

5. **Monitor CI build**
   ```bash
   gh run list --workflow=release.yml --limit=1
   gh run watch --exit-status
   ```

6. **Verify release artifacts**
   ```bash
   gh release view v0.1.0
   ```
   Should have:
   - banjo-darwin-arm64.tar.gz + .sha256
   - banjo-darwin-x64.tar.gz + .sha256
   - banjo-linux-x64.tar.gz + .sha256

7. **Update extension.toml with SHA256 hashes**
   ```bash
   # Download and get hashes from release
   gh release download v0.1.0 --pattern '*.sha256' --dir /tmp
   cat /tmp/*.sha256
   ```
   Add `sha256 = "..."` to each target in extension.toml

## Notes

- Version is defined in `src/acp/agent.zig` as `pub const version`
- Git hash is automatically appended at build time via build.zig
- CI builds for: darwin-arm64, darwin-x64, linux-x64
- After release, submit PR to zed-industries/extensions
