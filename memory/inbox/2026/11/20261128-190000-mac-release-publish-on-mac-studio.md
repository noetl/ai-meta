# macOS / arm64 release artifacts move to the Mac Studio
- Timestamp: 2026-11-28T19:00:00Z
- Author: noetl-ops (Grok Bot)
- Tags: build-placement,mac-studio,macos,arm64,github-actions,release

## Summary
Owner (2026-11-28, "сборки под мак на мак"): macOS and arm64 release builds run on the Mac Studio instead of GitHub runners.
After the 2026-11-27 `xcode-select -s /Library/Developer/CommandLineTools` fix, plain `cargo build --release` of cli links natively (781 s cold).
New script `ops/scripts/local-build/noetl-publish-mac.sh` builds the cli darwin-arm64 tarball and the server/worker linux/arm64 images from a release tag
and optionally uploads (`--upload`) or pushes (`--push`). Workflows skip the GitHub jobs unless `MACOS_BUILDS_ON_GITHUB` / `ARM_BUILDS_ON_GITHUB` is `true`.
Rule: `agents/rules/build-placement.md`.

## Related
- agents/rules/build-placement.md
