# Rust build policy: images on Cloud Build, on-box compiles through the capped queue
- Timestamp: 2026-11-14T17:28:20Z
- Author: claude-opus
- Tags: dev-host,cargo,build-queue,cloud-build,oom,memory

## Summary
The Mac Studio dev host (M1 Max, 32 GB) hung and needed a forced reset on 2026-11-13 (`btn_rst`, plus a JetsamEvent; swap 10.7/12 GB used) because concurrent agent cargo builds and tests exhausted RAM and swap. Policy from now on:

- **Release and container images go to Google Cloud Build** (`shastaratech-noetl-prod`, us-central1, E2_HIGHCPU_8) → `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/<image>`. Release tags: `release.yml` `publish-ar`. On demand: `gcb-build` in repos/server|worker|gateway pushes the dev tag `v0.0.0-dev.<sha>`. Verified: server-rust:v0.0.0-dev.765147ff@sha256:5c5ea52b… in 25m51s.
- **On-box compiles** (cargo check/test/clippy, arm64 kind images) go through `~/.cargo-queue`: a machine-wide flock semaphore with N=2 slots, plus `[build] jobs = 2`. Use `cargo-queue run podman build ...` for kind images.

Sizing at jobs=2: the worst-case build is 3.19 GiB (server test --no-run) versus 5.21 GiB at the old default; a release build is 1.53 GiB versus 3.01 GiB. N=2 → at most 6.4 GiB on top of a baseline of about 22 GiB, so the 32 GB host is enough and needs no bigger machine.

Cloud Build limits: E2_HIGHCPU_32 is refused even though the 64-vCPU quota is granted, and lifting that needs Google Cloud Support. In practice only one 8-vCPU build runs at a time, and queued builds expire after 1 h. A native worker compile previously timed out at 2400 s, so worker releases still compile on GHA and gcrane-copy to AR.

## Actions
- Installed ~/.cargo-queue (`cargo` wrapper, `cargo-queue`, `gcb-build`). Source and installer: scripts/dev-host/cargo-queue/.
- Wrote `[build] jobs = 2` to /Volumes/X10/dev/cargo/config.toml and ~/.cargo/config.toml (neither existed before).
- Added the PATH hook to ~/.zshenv, ~/.zshrc (end), ~/.bashrc and ~/.profile. Sessions started before the install need a restart.
- Verified with real builds: N=1 serialized 2 builds; N=2 ran 2 of 3 checks and queued the third; at most 4 rustc ran machine-wide.
- Found that noetl/server main tracks about 1.2 GB of build artifacts (target-kind/, .g4–.gb, since 749f5900). gcb-build excludes them; the repo still needs cleaning.

## Repos
- ai-meta (rule, playbook, scripts). Dev host only. Nothing was deployed and no cluster was touched.

## Related
- agents/rules/build-queue.md
- agents/rules/deployment-validation.md
- playbooks/dev-host-build-queue.md
