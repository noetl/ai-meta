# Rust build policy for the dev host (Mac Studio M1 Max, 32 GB)

**Why:** on 2026-11-13 the Mac hung and needed a forced reset after several
agent sessions ran `cargo build`/`cargo test` at once with default parallelism
(10 rustc jobs each). That filled RAM and the 12 GB swap. Two rules apply from now on:

| What you are building | Where it runs | How |
|---|---|---|
| **Any release / container image** (server, worker, gateway) whether for prod, AR, or "just check that the image builds" | **Off the Mac**: Google Cloud Build (`shastaratech-noetl-prod`, E2_HIGHCPU_8); worker *releases* on GitHub Actions + gcrane copy → Artifact Registry `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/<image>` | release tags: automatic in each repo's `release.yml` (`publish-ar`); on demand: `gcb-build` |
| **On-box compiles**: `cargo check/test/clippy` while iterating, and arm64 images for the local **kind** cluster (GCB is amd64-only, so kind images must be built here) | this Mac, through the **capped local queue** | plain `cargo ...` (auto-queued); `cargo-queue run podman build ...` for kind images |

Cloud Build only builds and publishes. Rolling an image to GKE prod stays
gated exactly as before (`agents/rules/deployment-validation.md`, kind first).
Never run `cargo build --release` of a whole service on the Mac just to
produce an image.

## Part 1 — Google Cloud Build (release and image builds)

State verified 2026-11-14:

| repo | GCB path | AR image | state |
|---|---|---|---|
| server | `cloudbuild.yaml` on **E2_HIGHCPU_8** (cargo-chef + buildx, registry cache `:buildcache`), triggered by `release.yml` `publish-ar` via WIF SA `gh-actions-cloudbuild@` | `noetl/server-rust` | **REAL, path of record**. 23/23 recent releases SUCCESS in 16–29 min; with the toolchain fix ([server#586](https://github.com/noetl/server/pull/586)) 17m47s cold |
| worker | **releases (path of record): GitHub Actions** builds `ghcr.io/noetl/worker`, then `cloudbuild-copy.yaml` gcrane-copies it to AR (about 10 s, digest checked). **On demand: native GCB** `cloudbuild.yaml` on E2_HIGHCPU_8, 3600 s timeout | `noetl/noetl-worker-rust` | **REAL both ways**. Native GCB was TIMEOUT before the toolchain fix ([worker#404](https://github.com/noetl/worker/pull/404)); after it, 34m26s cold, see below |
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

**On-demand path, verified 2026-11-14 (all on E2_HIGHCPU_8):**

| build | what | result |
|---|---|---|
| `c2c18ebc` us-central1 | server `origin/main` | SUCCESS 25m51s → `server-rust:v0.0.0-dev.765147ff@sha256:5c5ea52b…` (`:latest` untouched) |
| `5811fb54` us-east1 | server + toolchain fix | SUCCESS **17m47s** → `:v0.0.0-dev.62bc2396`, the **same digest** `5c5ea52b…` (reproducible: the fix changes only the build) |
| `d035b08a` us-central1 | worker `origin/main` | **TIMEOUT at 3600 s** (cook 27.6 min, then a full dependency recompile under the pinned toolchain) |
| `42b4ce97` us-central1 | worker + toolchain fix | SUCCESS **34m26s** cold (cook 1450 s, app 337 s, push 210 s) → `noetl-worker-rust:v0.0.0-dev.b7cf7ee2@sha256:e5895090…` |
| warm worker | source change, same `Cargo.lock` | SUCCESS **7m47s** (build `d6d19689`): cook layer from cache (37 s), app stage compiled only `noetl-worker` (314 s) → `:v0.0.0-dev.b7cf7ee2.dirty@sha256:c9148f35e0d7…` |

**Root cause of the slow and timed-out builds (fixed in server#586 and worker#404):** both
Dockerfiles ran `cargo chef cook` with the base image's Rust 1.91.1. `COPY . .` then
brought in `rust-toolchain.toml` (1.99.0), so the app stage recompiled every dependency
and the cached cook layer never helped. The fix copies the pin before `cook`. Other
tuning was not needed: cargo already uses all 8 vCPUs, and neither release profile
sets LTO or codegen-units. sccache is not worth the setup now that the cook layer
caches; revisit only if `Cargo.lock` churn makes cold builds common.

**Concurrency: one 8-vCPU build at a time per region.** A second build in the
same region waits in QUEUED and **expires after 1 h** (`queueTtl 3600s`). Other
regions run in parallel (the us-east1 build above ran alongside a us-central1
build) and still push to the us-central1 AR:

    GCB_REGION=us-east1 gcb-build        # second build while us-central1 is busy

**Machine types (probed 2026-11-14, project `shastaratech-noetl-prod`, default pool):**

| type | us-central1 | us-east1 | us-west1 |
|---|---|---|---|
| E2_HIGHCPU_8 | **provisions** | **provisions** | **provisions** |
| E2_HIGHCPU_32 | refused ("quota restrictions") | refused | refused |
| N1_HIGHCPU_32 | not allowed ("use E2 variants") | — | — |
| E2_HIGHCPU_16, E2_STANDARD_16, N2_HIGHCPU_16, C3_HIGHCPU_22 | not a default-pool type (gcloud rejects the config) | same | same |
| private pool (any type) | quota 4 vCPU | | |

So **E2_HIGHCPU_8 is the machine type**; switching region does not help.
Lifting the E2_HIGHCPU_32 restriction needs a Google Cloud Support case. That
is optional, and nothing waits on it.

## Part 2 — local build queue (on-box compiles only)

This queue caps how many heavy cargo commands run at once **across every shell
and every agent session**. Agents can still edit and run everything else in parallel.

### What is installed

Source: `scripts/dev-host/cargo-queue/` in ai-meta (`cargo`, `gcb-build`, `env.sh`, `install.sh`). Reinstall or update with `scripts/dev-host/cargo-queue/install.sh`, then copy this file to `~/.cargo-queue/README.md`.


| Piece | Where | Effect |
|---|---|---|
| rustc parallelism cap | `/Volumes/X10/dev/cargo/config.toml` **and** `~/.cargo/config.toml`: `[build] jobs = 2` | each cargo runs at most 2 rustc/linker jobs (two files because interactive shells set `CARGO_HOME=/Volumes/X10/dev/cargo`) |
| queue wrapper | `~/.cargo-queue/bin/cargo` (Python 3.9 stdlib only, `/usr/bin/python3`) | heavy subcommands wait for 1 of N global slots |
| PATH hook | `~/.cargo-queue/env.sh`, sourced from `~/.zshenv`, the end of `~/.zshrc`, `~/.bashrc` and `~/.profile` | puts the wrapper ahead of the rustup `cargo` in every new shell |\n| Claude Code hook | SessionStart hook `~/.cargo-queue/claude-session-start.sh` → `$CLAUDE_ENV_FILE` | needed because Claude Code's shell snapshot overrides the profile PATH |
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
- **Claude Code does not get PATH from the profile files.** Each session's shell
  snapshot re-exports the PATH of the Claude app process (here launched 09:12,
  before the 09:20 install), and that runs *after* `~/.zshenv`. So the profile
  hook alone left agents on `~/.cargo/bin/cargo` (seen 2026-11-15: a session's
  `cargo test` bypassed the queue). Two fixes, both installed by `install.sh`:
  - a user-level **SessionStart hook** in `~/.claude/settings.json`
    (`~/.cargo-queue/claude-session-start.sh`) appends the `env.sh` line to
    `$CLAUDE_ENV_FILE`, which Claude Code sources before every Bash command, after
    the snapshot. This covers every new session, whatever PATH the app has.
  - for sessions already running, the same line is appended to
    `~/.claude/shell-snapshots/snapshot-*.sh`. Each Bash call re-sources its snapshot,
    so the change applies on that session's next command.
- Check it inside any agent: `which cargo` must print `~/.cargo-queue/bin/cargo`.
  The `jobs = 2` cap applies even in shells where it doesn't.

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
