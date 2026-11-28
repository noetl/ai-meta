---
paths:
  - "**"
---

# Rust build policy on the Mac: on-box compiles through the queue

The Mac Studio dev host (M1 Max, 32 GB) runs many agent sessions at once.
On 2026-11-13 it hung and needed a forced reset after several sessions ran
`cargo build`/`cargo test` at the same time. Full runbook, measurements and
the current Cloud Build state: `playbooks/dev-host-build-queue.md`.

## 1. Release and container-image builds → AMD box / Mac (not Cloud Build)

**Superseded 2026-11-27 by [`build-placement.md`](build-placement.md)** (owner decision):
Linux/amd64 binaries and images are built on the AMD box (`kadyapam@10.50.0.89`),
Apple Silicon binaries and arm64 kind images on this Mac (through the queue below).
GitHub Actions runs lightweight checks only. Cloud Build (`gcb-build`, `gcloud builds
submit`) and Cloud Run need the owner's explicit OK; `gcb-build` refuses to run
without `--owner-approved`. On the Mac, build only Apple Silicon targets
(`aarch64-apple-darwin` release binaries, `linux/arm64` kind images), always through
the queue. Never build Linux/amd64 binaries or images on the Mac: run them on the AMD
box with `repos/ops/scripts/local-build/noetl-local-build.sh --remote amd`.

## 2. On-box compiles → the capped local queue

On-box means `cargo check/test/clippy` while iterating, and arm64 images for
the local kind cluster (Cloud Build is amd64-only).

- `[build] jobs = 2` in `$CARGO_HOME/config.toml` (both `/Volumes/X10/dev/cargo`
  and `~/.cargo`).
- `~/.cargo-queue/bin/cargo` comes first on PATH. It is a machine-wide
  semaphore, default **N=2** concurrent `build/test/check/clippy/run/bench/doc/
  install` across all sessions. `fmt`, `metadata` and the like are not gated.
- Run `cargo` as usual. Gate kind image builds with
  `cargo-queue run podman build ...`.
- If you see `[cargo-queue] ... queued`, wait. Do not kill and retry. Keep
  editing in the meantime. `cargo-queue status` shows the slot holders.
- Do not bypass: no `~/.cargo/bin/cargo` direct calls, no `CARGO_QUEUE_DISABLE=1`,
  no `-j` above 2, no `CARGO_BUILD_JOBS`, unless the user approves an emergency.
- Prefer `cargo check` and `cargo test -p <crate>` while iterating, and group
  verification into one test run.
- Check `which cargo` → `~/.cargo-queue/bin/cargo`. A SessionStart hook
  (`~/.claude/settings.json`) puts it on PATH in every Claude Code session. If it is
  missing, run `. ~/.cargo-queue/env.sh` in the command, or call `~/.cargo-queue/bin/cargo`,
  and report it. Never fall back to `~/.cargo/bin/cargo`.
- Change N (`~/.cargo-queue/slots`) only with the user's agreement. The sizing
  limit is N × 3.2 GiB (worst-case build at jobs=2) on top of about 22 GiB baseline.

This applies to the dev host only. It changes nothing in prod, CI or clusters.
