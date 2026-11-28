---
paths:
  - "**"
---

# Build placement: compile on our own machines, not in the cloud

**Owner decision, 2026-11-27.** Builds run on the Mount Shasta Ranch machines,
each one building what is native to it, to cut GitHub Actions and Google Cloud
usage. This supersedes the "images on Cloud Build" part of the 2026-11-14 policy
(`build-queue.md` §1, `playbooks/dev-host-build-queue.md` Part 1). The capped
local queue on the Mac (`build-queue.md` §2) still applies.

| Target | Where | Notes |
|---|---|---|
| **Linux / amd64**: `x86_64-unknown-linux-gnu` release binaries, `linux/amd64` container images, `.deb` packages | **AMD box** `ssh kadyapam@10.50.0.89` (Minisforum MS-A2, 32 cores, 60 GB RAM, Linux Mint 22.3, rootless podman, kind cluster `noetl`) | No build queue needed; checkouts in `~/projects/noetl/ai-meta/repos/*` |
| **Apple Silicon**: `aarch64-apple-darwin` binaries, `linux/arm64` images for the Mac kind cluster | **Mac Studio** (M1 Max, 32 GB) | Always through `~/.cargo-queue` (`build-queue.md` §2) |
| Lightweight checks: fmt, clippy, unit/integration tests on PRs, YAML/doc validation | **GitHub Actions** | Keep `concurrency` + cancel-in-progress; cache saved only from `main` |
| Anything on **Google Cloud Build / Cloud Run** (including `gcb-build`) | **Only with the owner's explicit OK** in the current conversation | `gcb-build` now refuses to run without `--owner-approved` |

## Rules for every agent

1. **Do not cross-compile.** Linux artifacts are built on the AMD box, Apple
   Silicon artifacts on the Mac. From the Mac, use the `--remote amd` mode of the
   local build script (it syncs the tracked tree, including uncommitted edits).
2. **GitHub Actions is for checks, not builds.** Do not add heavy, multi-arch or
   matrix build jobs, new macOS runners, or scheduled heavy jobs. Do not dispatch
   `release.yml` (or re-run a release) just to see whether something builds:
   build it locally. Keep `paths`/`concurrency` filters on new workflows.
   Changing or disabling an existing release/deploy job is an owner decision:
   propose it in a PR and say so, never remove it silently.
3. **No Cloud Build / Cloud Run builds or deploys without the owner's OK.** That
   includes `gcloud builds submit`, `gcb-build`, and `gcloud run deploy`.
   Read-only `gcloud ... list/describe` is fine.
4. **Mac Studio memory guard still applies:** every heavy cargo/podman command on
   the Mac goes through `~/.cargo-queue` (never bypass it).
5. **The AMD box is shared.** Another agent (AMD Box DevOps) owns the host and
   the kind cluster lifecycle. Do not prune images/volumes, reboot, upgrade
   packages, recreate the cluster, or touch the `home-network-viz` service on
   port 8080. Build in your own clone/worktree (e.g. `~/build-policy/<repo>` or
   `git worktree add`), not in a checkout another agent is editing.
6. **AMD has no GitHub push credentials.** Push from the Mac (or via the Mac with
   `ssh -A`); never copy keys or tokens to the AMD box yourself.

## How to build

Script: `repos/ops/scripts/local-build/noetl-local-build.sh` (noetl/ops).

```bash
# On the AMD box (linux-x86_64) or the Mac (darwin-arm64): native release binaries
cd ~/projects/noetl/ai-meta/repos/ops            # Mac: /Volumes/X10/projects/noetl/ai-meta/repos/ops
scripts/local-build/noetl-local-build.sh --repos server,worker,cli
#   -> ~/noetl-build/out/<platform>-<stamp>/{<repo>-<ver>-g<sha>-<platform>.tar.gz,SHA256SUMS,build-times.tsv}

# Native container image (linux/amd64 on AMD, linux/arm64 on the Mac), optionally into kind
scripts/local-build/noetl-local-build.sh --repos server,worker --image --kind-load noetl

# From the Mac: run the Linux build on the AMD box
scripts/local-build/noetl-local-build.sh --repos server,worker,cli --remote amd

# Push to a registry: explicit only, after `podman login` by the owner
scripts/local-build/noetl-local-build.sh --repos server --image --push ghcr.io/noetl
```

Full kind deploys keep using `repos/ops/automation/development/noetl.yaml`; it
builds native images on whichever host it runs on.

Measured on 2026-11-27 (release profile, warm toolchain, cold `target/`): see
`memory/inbox/2026/11/20261127-*-build-placement-amd-mac.md`.

## Release pipelines (GitHub Actions)

Release workflows still run on GitHub Actions by default. Two switches, both
repository variables the owner sets (nothing changes until then):

- `RELEASE_BUILDS_ON_MERGE=false` (server, worker, cli): semantic-release still
  tags and writes notes, but no longer dispatches the multi-arch release build
  after every merge. Build on the AMD box / Mac, or dispatch by hand.
- server `SERVER_AR_SOURCE=cloudbuild` restores the old second compile on Cloud
  Build. The default after server's CI PR is a gcrane copy GHCR → Artifact
  Registry, the same as the worker since ai-meta#515.

## Apple Silicon / macOS release artifacts: built on the Mac Studio (owner decision 2026-11-28)

"Сборки под мак на мак": what GitHub used to build on paid macOS and arm64 runners is built on the Mac Studio with
`repos/ops/scripts/local-build/noetl-publish-mac.sh` (Apple Silicon only; it refuses to run elsewhere):

- **cli** `darwin-arm64` tarball: `--repo cli --version X.Y.Z --upload` (attaches `noetl-vX.Y.Z-darwin-arm64.tar.gz` and a `.sha256` to the GitHub release).
- **server / worker** `linux/arm64` image: `--repo server|worker --version X.Y.Z --push` pushes `ghcr.io/noetl/<repo>:X.Y.Z-arm64`
  and dispatches that repo's `assemble-multiarch-manifest.yml` (metadata only) to join it with the `-amd64` image.
- Nothing leaves the Mac without `--upload` / `--push`. `--push` needs `podman login ghcr.io` (token with `write:packages`).
- The release workflows skip these jobs unless the repo variable `MACOS_BUILDS_ON_GITHUB` (cli) / `ARM_BUILDS_ON_GITHUB` (server, worker)
  is `true`; that is the rollback switch. `:latest` of the images moves only when both architectures exist.
- Still on GitHub: cli `linux-aarch64` tarball and the arm64 `.deb` (the apt index needs it, ai-meta#390), gateway/tools/catalog arm64 images.
- Homebrew needs no binary: the tap formula builds from the source tarball (`cargo install`).
