# Build placement: Linux builds on the AMD box, Apple Silicon on the Mac, no Cloud Build without OK
- Timestamp: 2026-11-28T01:45:00Z
- Author: noetl-ops (Grok Bot)
- Tags: build-placement,amd-box,mac-studio,github-actions,cloud-build,cost

## Summary
Owner decision, 2026-11-27: compile on the Mount Shasta Ranch machines, each building what is native to it. Linux/amd64 goes to the AMD box (`kadyapam@10.50.0.89`, MS-A2, 32 cores, 60 GB, Linux Mint 22.3). Apple Silicon goes to the Mac Studio, through `~/.cargo-queue`. GitHub Actions is for checks only. Cloud Build and Cloud Run need the owner's OK. This supersedes the "images on Cloud Build" half of 20261114-172820. Rule: `agents/rules/build-placement.md`.

## Audit (2026-10-28 .. 2026-11-27)
- **Actions minutes, Oct:** worker 4,640 Linux + 1,482 ARM; server 2,837 + 623; ehdb 1,000; noetl 175 macOS; cli 118 macOS.
- **Actions minutes, Nov to the 27th:** server 2,437 + 536 ARM; worker 1,366 + 738 ARM; cli 557 + 262 ARM + 177 macOS; ehdb 518; ai-meta 439; book 315 + 65 macOS.
- **Net billed: $0.** It is all in the free or included allowance; gross list value is about $70 in Oct.
- **Biggest consumer: release workflows dispatched by semantic-release on every feat/fix merge.**
  - server: 36 runs, each amd64 + arm64 on GHA (12–15 min) plus publish-ar recompiling on Cloud Build (17–22 min).
  - worker: 17 runs (amd64 28–33 min, arm64 24 min).
  - cli: 11 runs, including the macOS runner.
- **Cloud Build in shastaratech-noetl-prod:** ≥43 E2_HIGHCPU_8 builds, ~990 build-min, almost all server publish-ar, plus the worker gcrane copies.
- **Cloud Run:** no services in any accessible project; the API is disabled in shastaratech-noetl-prod.

## Build timings measured on 2026-11-27 (cold target/, release profile)
- AMD (no cap): server 59 s, worker 141 s, cli 120 s. podman linux/amd64 images: server 397 s, worker 483 s, cli 532 s.
- Mac Studio (cargo-queue, jobs=2): server 387 s, worker 949 s, cli 779 s.
- `--remote amd` from the Mac takes about 2¼ min end to end (cli, server).

## Found
- **The Mac Studio can't link natively with the default toolchain.** After the 2026-11-25 CLT 27.2 update, xcode-select still points at Xcode.app (clang 17), and its ld rejects the CLT SDK's `arm64e.x1` tbd files. Every `cargo build` fails at link time.
  - Workaround: `DEVELOPER_DIR=/Library/Developer/CommandLineTools`. The ops script applies it automatically.
  - Permanent fix (owner, sudo): `xcode-select -s /Library/Developer/CommandLineTools`, or update Xcode.app.

## Actions
- **PRs:**
  - ops#398: `scripts/local-build/noetl-local-build.sh`.
  - ai-meta#597: rule, pointers, and the gcb-build `--owner-approved` guard.
  - server#604: publish-ar copies GHCR→AR instead of recompiling.
  - worker#409 and cli#116: `RELEASE_BUILDS_ON_MERGE` switch and rust cache saved from main only.
  - ehdb#442, ehgraph#24, quantum#36: concurrency, caching, benchmarks off the per-PR path.
- **Machine-level agent instructions** (appended, with backups):
  - Mac: `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.gemini/GEMINI.md`.
  - AMD: `~/AGENTS.md`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`.
  - Canonical copy on both: `~/.config/mount-shasta/BUILD-POLICY.md`.
- **Installed the guarded `gcb-build`** at `~/.cargo-queue/bin/gcb-build` on the Mac. The backup is `~/.cargo-queue/gcb-build.bak-buildpolicy-20261127-171857`.

## Related
- agents/rules/build-placement.md, agents/rules/build-queue.md
- memory/inbox/2026/11/20261114-172820-rust-build-policy-gcb-images-local-queue.md
