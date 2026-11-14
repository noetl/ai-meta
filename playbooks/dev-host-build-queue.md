# Rust build policy for the dev host (Mac Studio M1 Max, 32 GB)

**Why:** on 2026-11-13 the Mac hung and needed a forced reset after several
agent sessions ran `cargo build`/`cargo test` at once with default parallelism
(10 rustc jobs each). That filled RAM and the 12 GB swap. Two rules apply from now on:

| What you are building | Where it runs | How |
|---|---|---|
| **Any release / container image** (server, worker, gateway) whether for prod, AR, or "just check that the image builds" | **Google Cloud Build** (`shastaratech-noetl-prod`, us-central1, E2_HIGHCPU_8) → Artifact Registry `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/<image>` | release tags: automatic in each repo's `release.yml` (`publish-ar`); on demand: `gcb-build` |
| **On-box compiles**: `cargo check/test/clippy` while iterating, and arm64 images for the local **kind** cluster (GCB is amd64-only, so kind images must be built here) | this Mac, through the **capped local queue** | plain `cargo ...` (auto-queued); `cargo-queue run podman build ...` for kind images |

Cloud Build only builds and publishes. Rolling an image to GKE prod stays
gated exactly as before (`agents/rules/deployment-validation.md`, kind first).
Never run `cargo build --release` of a whole service on the Mac just to
produce an image.

## Part 1 — Google Cloud Build (release and image builds)

State verified 2026-11-14:

| repo | GCB path | AR image | state |
|---|---|---|---|
| server | `cloudbuild.yaml` (cargo-chef + buildx, registry cache `:buildcache`), triggered by `release.yml` `publish-ar` via WIF SA `gh-actions-cloudbuild@` | `noetl/server-rust` | **REAL**. 23/23 recent release builds SUCCESS, 16–29 min |
| worker | releases: GHA builds GHCR `ghcr.io/noetl/worker`, then `cloudbuild-copy.yaml` `gcrane` copies it to AR (about 10 s, digest checked) | `noetl/noetl-worker-rust` | **REAL (copy)**. A native GCB compile timed out at 2400 s on E2_HIGHCPU_8 (6.11.3, 6.11.4); `gcb-build` raises it to 3600 s, see below |
| gateway | no `cloudbuild.yaml`; `gcloud builds submit --tag` (v3.20.0 took 242 s) / `gcb-build` | `noetl/noetl-gateway` | **REAL (manual)** |
| ehdb | library, no image. `ci/cloudbuild-chain-cert-amd64.yaml` runs an amd64 test probe | — | n/a |

**On-demand build + publish from a session** (`~/.cargo-queue/bin/gcb-build`,
source in ai-meta `scripts/dev-host/cargo-queue/gcb-build`):

    cd repos/server && gcb-build             # dev image  server-rust:v0.0.0-dev.<sha>[.dirty]
    cd repos/worker && gcb-build             # dev image  noetl-worker-rust:v0.0.0-dev.<sha>  (timeout 3600 s)
    cd repos/gateway && gcb-build            # dev image  noetl-gateway:v0.0.0-dev.<sha>
    gcb-build --dry-run                      # print the gcloud command only
    gcb-build --version 3.163.0              # re-publish a release from its tag (only when CI publish-ar failed)

It uploads a `git archive` of tracked files (uncommitted edits to tracked files
included, marked `.dirty`; `target*/` and the `.g?/` binaries that noetl/server
wrongly tracks are excluded, so 433 MB becomes 1.7 MB). It never moves `:latest`
unless you pass `--version X --latest`, and it prints the `@sha256` digest at the end. The underlying call is

    gcloud builds submit src.tgz --project=shastaratech-noetl-prod --region=us-central1 \
      --config=cloudbuild.yaml --gcs-source-staging-dir=gs://shastaratech-noetl-prod_cloudbuild/source \
      --substitutions=_VERSION=<ver>,_PUSH_LATEST=false

Prereqs: `gcloud` account with Cloud Build access on `shastaratech-noetl-prod`
(the default gcloud config on the dev host has it). Builds bill to that
project, at about $0.016 per build-minute on E2_HIGHCPU_8.

**On-demand path, verified 2026-11-14:** `gcb-build` from a clean `origin/main`
of noetl/server built and published
`server-rust:v0.0.0-dev.765147ff@sha256:5c5ea52b0492796907cca0db30a3a4dcb8c33ac7894d7f4e25eca2feb3d55f5f`
(build `c2c18ebc`, 25m51s, 1.7 MB upload); `:latest` was not moved. Worker dev build `d035b08a` (native compile, 3600 s timeout): running, result pending.

**GCB runs one 8-vCPU build at a time in this project.** A second build waits
in QUEUED (the worker dev build started 56 s after the server build finished)
and **expires after 1 h in the queue** (`queueTtl 3600s`). Plan for about 25
minutes per server build, run back to back. The likely cause is the default
10-vCPU ongoing-build limit; the granted 64-vCPU value is on another
dimension. Raising it is a quota request in the console (IAM & Admin > Quotas,
`cloudbuild.googleapis.com`). That is optional and needs the user.

**Blocked: needs the user.** `E2_HIGHCPU_32` is still refused
("due to quota restrictions, Cloud Build cannot run builds of this machine type
in this region"), **even though** the `Cloud Build CPUs` quota in us-central1
is 64 (granted). That restriction is separate and only Google Cloud Support
lifts it (support case on project `shastaratech-noetl-prod`). N1 types are not
allowed in us-central1, and the private-pool quota is 4 vCPU. Until it is
lifted, builds run on 8 vCPU. Once it lands, change `machineType` to
`E2_HIGHCPU_32` in server/worker `cloudbuild.yaml` (a one-line change), and
worker releases can compile natively again.

## Part 2 — local build queue (on-box compiles only)

This queue caps how many heavy cargo commands run at once **across every shell
and every agent session**. Agents can still edit and run everything else in parallel.

### What is installed

Source: `scripts/dev-host/cargo-queue/` in ai-meta (`cargo`, `gcb-build`, `env.sh`, `install.sh`). Reinstall or update with `scripts/dev-host/cargo-queue/install.sh`, then copy this file to `~/.cargo-queue/README.md`.


| Piece | Where | Effect |
|---|---|---|
| rustc parallelism cap | `/Volumes/X10/dev/cargo/config.toml` **and** `~/.cargo/config.toml`: `[build] jobs = 2` | each cargo runs at most 2 rustc/linker jobs (two files because interactive shells set `CARGO_HOME=/Volumes/X10/dev/cargo`) |
| queue wrapper | `~/.cargo-queue/bin/cargo` (Python 3.9 stdlib only, `/usr/bin/python3`) | heavy subcommands wait for 1 of N global slots |
| PATH hook | `~/.cargo-queue/env.sh`, sourced from `~/.zshenv`, the end of `~/.zshrc`, `~/.bashrc` and `~/.profile` | puts the wrapper ahead of the rustup `cargo` in every new shell |
| slot count | `~/.cargo-queue/slots` (one integer, read on every call) | default N |
| locks | `~/.cargo-queue/locks/slot-K.lock`, `turnstile.lock`, `waiting/` | `fcntl.flock`; the kernel drops a lock when its holder dies, so no lock goes stale |

**Gated (wait for a slot):** `build b test t check c clippy run r bench doc d
install rustc rustdoc fix nextest llvm-cov miri mutants zigbuild`.
`cargo run` holds the slot only for its build step; the program itself runs
outside the queue.

**Not gated (run immediately):** `fmt`, `metadata`, `tree`, `update`, `add`,
`--version`, any `--help`, and anything else not listed above. A cargo that runs
inside a gated cargo (build scripts, `cargo clippy` → cargo) sees
`CARGO_QUEUE_HELD=1` and passes straight through, so nested calls cannot deadlock.

### Using it (agents)

Run `cargo` as usual. Nothing changes except that a heavy command may print

    [cargo-queue] all 2 build slots busy, queued (see `cargo-queue status`)

and wait; it prints `got slot K/N after Ns` when it starts. **Do not kill and
retry a waiting build.** It is in line. Keep editing meanwhile.

    cargo-queue status            # who holds each slot and who is waiting
    cargo-queue run podman build ...   # gate a kind image build (or any heavy command) the same way
    cargo queue-status            # same

- Do not pass `-j 8` or set `CARGO_BUILD_JOBS` to raise parallelism; that brings back the OOM.
- A shell started **before** the install has the old PATH. Claude Code sessions
  keep a shell snapshot, so start a new session, or call
  `~/.cargo-queue/bin/cargo ...` explicitly. The `jobs = 2` cap applies right
  away even in old shells.

### Tuning

    echo 1 > ~/.cargo-queue/slots          # machine-wide, takes effect on the next cargo call
    CARGO_QUEUE_SLOTS=3 cargo build        # one invocation only
    CARGO_QUEUE_TIMEOUT=600 cargo test     # give up (exit 75) after 10 minutes in the queue

Per-build memory scales with `jobs`. Keep **N × jobs ≤ 4–6** on this 32 GB host
(see "Sizing" below). Total rustc parallelism is N × jobs (2 × 2 = 4 by default).

### Emergency bypass

    CARGO_QUEUE_DISABLE=1 cargo build      # skip the queue for one call (jobs cap still applies)
    ~/.cargo/bin/cargo build               # call the real rustup cargo directly
    cargo build -j 8                       # override the jobs cap for one call (only when nothing else is building)

Uninstall: delete the `cargo-queue/env.sh` line from the four profiles (backups
are named `*.bak-cargoqueue-*`), then `rm -rf ~/.cargo-queue`.

rust-analyzer's `cargo check` also goes through the queue when the editor
inherits the shell PATH. If the editor's diagnostics lag behind long builds, set
`"rust-analyzer.check.extraEnv": {"CARGO_QUEUE_DISABLE": "1"}`.

### Sizing (measured 2026-11-14, noetl-server 3.112.3, clean target dirs)

Sampled sum of RSS over cargo's whole process tree (rustc, linker, build scripts) every 0.5 s:

| build | jobs | wall | peak tree RSS | largest single rustc |
|---|---|---|---|---|
| `build --release` | 10 (old default) | 91 s | **3.01 GiB** | 2.25 GiB |
| `build --release` | **2** | 264 s | **1.53 GiB** | 1.48 GiB |
| `test --no-run` (debug) | 10 (old default) | 55 s | **5.21 GiB** | 1.68 GiB |
| `test --no-run` (debug) | **2** | 129 s | **3.19 GiB** | 1.70 GiB |

Host baseline with no builds running: about **22 GiB** in use (active + wired +
compressor). That includes a 6.4 GiB Virtualization VM (podman/colima), Chrome,
the Claude/Codex/ChatGPT apps and others. Swap was already 10.7 of 12 GB used.
That leaves about **10 GiB** for builds.

- Before: k agent sessions × up to 5.2 GiB each, unbounded. Three or four
  sessions running `cargo test` at once need 16–21 GiB on top of 22 GiB, which
  exceeds RAM plus the free swap. The host thrashes, hangs and needs a forced reset.
- After: N=2 × 3.2 GiB worst case = **6.4 GiB** → about 28.4 GiB of 32 GiB, with no
  swap growth. N=3 would reach about 31.6 GiB, too close to the limit. **Default N=2.**
- Cost: a single build is 1.5–2.9× slower (no more than 2 rustc jobs). Machine-wide
  throughput stays reasonable: 4 rustc jobs on 8 performance cores.

**Verdict:** with the queue, the M1 Max 32 GB is enough for this workload. No
bigger machine or build grid is needed. Raise N only after shrinking the baseline
(for example, stop the 6.4 GiB VM when it is not needed).
