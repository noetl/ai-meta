---
paths:
  - "**"
---

# Rust build policy: images on Cloud Build, on-box compiles through the queue

The Mac Studio dev host (M1 Max, 32 GB) runs many agent sessions at once.
On 2026-11-13 it hung and needed a forced reset after several sessions ran
`cargo build`/`cargo test` at the same time. Full runbook, measurements and
the current Cloud Build state: `playbooks/dev-host-build-queue.md`.

## 1. Release and container-image builds → Google Cloud Build

- Every image (server, worker, gateway), for prod, for Artifact Registry, or
  just to check that the image builds, is compiled on **Google Cloud Build**
  (`shastaratech-noetl-prod`, us-central1) and lands in
  `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/<image>`.
- Release tags: the repo's `release.yml` `publish-ar` job does it on merge.
  Do not build release images by hand.
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
- If `which cargo` is not `~/.cargo-queue/bin/cargo`, your shell predates the
  install: start a new session or call `~/.cargo-queue/bin/cargo`.
- Change N (`~/.cargo-queue/slots`) only with the user's agreement. The sizing
  limit is N × 3.2 GiB (worst-case build at jobs=2) on top of about 22 GiB baseline.

This applies to the dev host only. It changes nothing in prod, CI or clusters.
