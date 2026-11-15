---
paths:
  - "**"
---

# Rust build policy: images on Cloud Build, on-box compiles through the queue

The Mac Studio dev host (M1 Max, 32 GB) runs many agent sessions at once.
On 2026-11-13 it hung and needed a forced reset after several sessions ran
`cargo build`/`cargo test` at the same time. Full runbook, measurements and
the current Cloud Build state: `playbooks/dev-host-build-queue.md`.

## 1. Release and container-image builds → off the Mac (Cloud Build / GitHub Actions)

- Every image (server, worker, gateway), for prod, for Artifact Registry, or
  just to check that the image builds, is compiled **off the Mac**: on Google
  Cloud Build (`shastaratech-noetl-prod`), or on GitHub Actions for worker
  releases. It lands in
  `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/<image>`.
- Release tags: the repo's `release.yml` does it on merge. Do not build
  release images by hand. **server**: compiled on Cloud Build. **worker**:
  compiled on GitHub Actions (GHCR), then gcrane-copied to AR. That split is
  the path of record. A native Cloud Build worker build also works since
  worker#404 (E2_HIGHCPU_8: about 34 min cold, about 8 min warm when `Cargo.lock` is unchanged; 3600 s timeout).
- Machine type: **E2_HIGHCPU_8** is the largest that provisions. E2_HIGHCPU_32
  is refused in every region tried; do not wait on it. One build runs at a
  time per region, and queued builds expire after 1 h. For a parallel build,
  use `GCB_REGION=us-east1 gcb-build`.
- On demand from a session: `cd repos/<server|worker|gateway> && gcb-build`
  pushes a dev tag `v0.0.0-dev.<sha>[.dirty]` and prints the digest. It never
  moves `:latest`.
- Do **not** run `cargo build --release` of a whole service, or `docker/podman
  build` of an amd64 image, on the Mac to produce an image.
- Cloud Build only builds and publishes. Rolling an image to GKE stays gated
  as before (`deployment-validation.md`: kind first, prod only with approval).

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
