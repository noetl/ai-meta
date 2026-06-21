# Current Memory

Snapshot of the working state as of **2026-06-09**. Older detail has
been compacted into `memory/compactions/` and archived under
`memory/archive/`. Read the latest compaction
(`memory/compactions/20260609-025209.md`) for the most recent batch.

## Active Focus

### Cross-repo orchestration (durable)

- This is `ai-meta`: the meta-repo coordinating NoETL submodules.
  Implement product code in submodules; commit only AI instructions,
  orchestration docs, memory, and submodule pointer bumps here.
- Standard cross-repo workflow: branch in submodule → upstream PR
  merges → bump submodule pointer here with
  `chore(sync): bump <repo> to <short-sha>`.
- Local kind deploys must use the configured Podman machine
  (`noetl-dev`); never fall back to Colima/Docker. Mount
  `/Volumes:/Volumes` for kind extraMounts to work.
- **Deployment validation order: local kind → GKE.** Any change that
  ships in a container image must be validated on the local kind
  cluster (context `kind-noetl`) BEFORE rolling out to GKE.
  Exceptions: documentation-only changes, dev-only scaffolds.
- Local NoETL CLI baseline: `noetl 4.9.0` at
  `/Volumes/X10/dev/cargo/bin/noetl`.
- GCP project `noetl-demo-19700101` is operated under the **Adiona.org**
  organization context.

### Standing directions

- **Rust-only focus** (2026-06-04): ignore Python-related tasks.
  The Rust stack (server + worker + tools + gateway + CLI) is the
  target. Python pieces stay deployable for backwards-compat but
  are NOT a target for new work.
- **Claude writes Rust directly** (2026-06-08): do not dispatch Codex
  for Rust changes. Claude reads, edits, builds, tests, and opens
  PRs end-to-end. Codified in `agents/rules/handoff-routing.md`.

### Open ai-task umbrellas

Only **one** umbrella remains open:

| # | Title | Status |
|---|---|---|
| 49 | Rust server FastAPI parity port — full HTTP API in noetl/server crate | Phases A–F shipped. All e2e regression findings (#53–#76) closed. Only R5 (production cutover to Rust-only on GKE) remains — that's an ops decision, not a code task. |

### EHDB platform storage track

- EHDB (`repos/ehdb`) is now the NoETL Event Horizon Database project:
  an Arrow-native NoETL-domain storage system intended to become the
  core substrate for operational metadata, first-class catalog state,
  event streams, RAG/retrieval state, and historical analytical data.
  Do not frame EHDB as a generic database first.
- EHDB's long-term NoETL dependency-collapse target is to absorb roles
  currently served by PostgreSQL, NATS JetStream, external object
  stores, Qdrant, and ClickHouse into EHDB-owned capabilities. Track
  this scope in `noetl/ehdb#6`.
- EHDB design source of truth lives in `repos/ehdb-wiki` and the GitHub
  wiki: https://github.com/noetl/ehdb/wiki. Do not duplicate the full
  project design in `ai-meta`; keep `ai-meta` memory focused on
  pointer, platform-boundary, and integration-state notes.
- Initial EHDB issues opened in `noetl/ehdb`: #1 bootstrap Rust
  workspace/CI, #2 catalog-as-database model, #3 immutable object
  storage layer, #4 transaction log/MVCC boundary, #5 NoETL system-store
  integration path. Project board target:
  https://github.com/orgs/noetl/projects/4/views/1.
- `noetl/ehdb#7` merged on 2026-06-21 as
  `a36949774e67fcfdda4de4f9de55fb0dc420c037`, establishing the first
  reliable pre-service reference implementation: `ehdb-stream`,
  `ehdb-retrieval`, `ehdb-transaction`, cross-domain integration
  coverage, 25 tests, Clippy clean, benchmark compilation, and
  Criterion baselines. `repos/ehdb` should point at this merged SHA.
- `noetl/ehdb#9` merged on 2026-06-21 as
  `50bd09f7ecde206e912a74e4072e997a07da9728`, closing issue #8 and
  adding the local durable transaction-log reference:
  `LocalJsonlTransactionLog` with fsynced JSONL append, restart replay,
  duplicate transaction ID checks, sequence/corruption validation,
  28-test coverage, and benchmark baselines. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `c68f8dd`.
- `noetl/ehdb#11` merged on 2026-06-21 as
  `96b50a3f0c9a539b3e4baef11b4ffc7f9aca4db6`, closing issue #10 and
  adding the local durable stream-journal reference:
  `LocalJsonlStreamLog` with fsynced JSONL create-stream,
  create-consumer, publish, and ack journaling; restart replay restores
  retained records, durable consumer cursors, and next sequence.
  Current coverage is 31 Rust tests plus Criterion baselines. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `cbc4794`.
- `noetl/ehdb#13` merged on 2026-06-21 as
  `039adefdb7f15076283e2ef38c53f9f7207282a9`, closing issue #12 and
  adding `ehdb-system`, the EHDB catalog/storage side of NoETL system
  WASM libraries: immutable module manifests plus mutable
  tenant/namespace/environment/channel bindings. Stable bindings can be
  rebound to new digest/revision values for hot replacement without
  Rust crate semantic-version churn. System publish/bind mutations are
  now replayable transaction-log state. Current coverage is 36 Rust
  tests plus Criterion baselines. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `9df35a1`.
- `noetl/ehdb#15` merged on 2026-06-21 as
  `e80fc839f03e021d315ba409253697af21d2d6e0`, closing issue #14 and
  adding `LocalJsonlSystemLibraryCatalog`, a fsynced JSONL journal for
  system WASM library publish/bind operations. Reopen rebuilds
  immutable manifests and mutable environment/channel bindings, so
  hot-replacement state survives local restart. Current coverage is 39
  Rust tests plus benchmark compilation. `repos/ehdb` should point at
  this merged SHA; `repos/ehdb-wiki` should point at `f2d9ec5`.
- `noetl/ehdb#17` merged on 2026-06-21 as
  `16b65db228bd4b6540f595384b0c48ba4c7db0d6`, closing issue #16 and
  making transaction mutations replay-complete. `ehdb-reference` can
  rebuild catalog, stream, retrieval, and system-library reference state
  from `TransactionRecord` replay alone; unexpected stream sequence
  values fail deterministically. Current coverage is 41 Rust tests plus
  Criterion baselines. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `e165293`.
- `noetl/ehdb#19` merged on 2026-06-21 as
  `84643386ba21b520003c956168cfbb3eae00dd86`, closing issue #18 and
  adding `LocalReferenceRuntime` over `LocalJsonlTransactionLog`.
  The runtime previews transaction records, applies them to cloned
  reference state before durable append, prevents invalid projected
  commits from advancing the JSONL log, and rebuilds catalog, stream,
  retrieval, and system-library projections from replay on reopen.
  Current coverage is 43 Rust tests plus Criterion baselines. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `1e1f3bf`.
- Preserve the NoETL execution-model boundary while integrating EHDB:
  gateway = gatekeeper, worker = atomic compute, playbook = ephemeral
  blueprint, shared cache = state vehicle, event log = source of truth.
  EHDB must not introduce gateway direct database touch or persistent
  per-tenant agent/MCP processes.

### Recently closed umbrellas (June 2026)

| # | Title | Closed |
|---|---|---|
| 77 | Explicit input binding (BREAKING v3.0.0 tools + server) | 2026-06-09 |
| 76 | Sequential-mode iterator: serialize per-iteration commands | 2026-06-08 |
| 75 | PlaybookTool polling fix | 2026-06-08 |
| 74 | ctx/workload namespace shim | 2026-06-08 |
| 73 | Arc-level set propagation (2 gaps) | 2026-06-08 |
| 72 | Status endpoint in-flight check | 2026-06-08 |
| 71 | noetl-tools python wrapper input_data + top-level return | 2026-06-08 |
| 70 | result_store PUT/resolve endpoints | 2026-06-07 |
| 69 | step.data context accessor | 2026-06-07 |
| 68 | Worker pending_callback adoption | 2026-06-07 |
| 67 | Catalog INT4 fix | 2026-06-07 |
| 66 | build_context step.data accessor | 2026-06-07 |
| 65 | noetl-tools python script loaders | parked (Rust-only) |
| 64 | noetl-tools artifact tool kind | parked |
| 61 | Secrets Wallet | 2026-06-07 |
| 43 | Container Tool Callback | 2026-06-07 |

### Ecosystem versions (ai-meta pointers)

| Component | Version | Pointer |
|---|---|---|
| noetl-server | v3.0.0 | `0f8dc63` |
| noetl-tools | v3.0.0 | `fdbc407` |
| noetl-worker | ~v5.15.0 | `8dd653b` |
| noetl-gateway | v3.2.0 | `335b86f` |
| noetl-cli | v4.10.0 | `c73f99d` |
| noetl-e2e | — | `f6a9a93` |
| noetl (Python) | ~v2.5.5 | `5f9a07d` |

### Key architecture shipped

- **DB sharding** (Phase F R4): `DatabaseConfig` + `DbPoolMap` with
  N+1 pools, per-execution handler cutover, cluster-wide list
  fan-out + event_id resolver. Kind-validated with N=2 shards.
- **Shard routing** (Phase F R3): gateway path-param + body-param
  routing; server + gateway shard-info endpoints; ops drift-guard.
- **Snowflake IDs** (Phase F R1.5): app-side generation on server.
- **Orchestrator engine** (Phase D): step.when guards, iterator
  fan-out (sequential + parallel), parallel branch completion,
  fanout/reduce. All kind-validated on Rust-only stack.
- **Secrets Wallet**: envelope encryption + Cloud KMS + 5 static +
  3 dynamic secret providers + residency policy + cross-region
  broker + KEK rotation + audit.
- **Container Tool Callback**: K8s Job dispatch + k8s-watcher +
  terminal-state callback to server.
- **noetl-events crate**: shared event types across CLI, server,
  worker. Published on crates.io.
- **noetl-executor crate**: extracted from CLI, adopted by worker.
  Published on crates.io (v0.5.0).
- **Explicit input binding** (#77): BREAKING v3.0.0 across
  noetl-tools + noetl-server. Data flows forward through
  `set:` → `input:`, never backward via `_prev`/`_results`.
  All 13 e2e fixtures migrated.

## Conventions to honor

- When a task spans more than one AI session, use a file-based
  handoff (`handoffs/active/<slug>/`) or an ai-task issue.
- NoETL release commit subjects use no scope braces
  (`fix: ...`, not `fix(scope): ...`) so semantic-release
  automation triggers correctly.
- Logging hygiene: suppress access logs or use DEBUG for
  high-frequency health/poll endpoints.
- Wiki maintenance: four pages drift together (Home, Sessions-Log,
  Releases, Umbrella-*). A change set touching only one is
  incomplete.
- Roadmap board 3 auto-moves closed issues to Done; verify rather
  than assume.

## Compaction History

- 2026-06-09 — `memory/compactions/20260609-025209.md` (6 entries:
  R-3 Phase B, EE-4, Rust-only direction, #61/#43 closed, Phase D R4)
- 2026-06-02 — `memory/compactions/20260602-012917.md`
- 2026-05-29 — `memory/compactions/20260529-024139.md`
- 2026-05-26 — `memory/compactions/20260526-063333.md`
- 2026-05-24 — `memory/compactions/20260524-055140.md`
- 2026-05-24 — `memory/compactions/20260524-002005.md`
- 2026-05-23 — `memory/compactions/20260523-052525.md`
- 2026-05-15 — `memory/compactions/20260515-173703.md`
- 2026-05-15 — previous compactions in archive
