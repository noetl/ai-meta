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
- `noetl/ehdb#21` merged on 2026-06-21 as
  `26911884d49b54c158e1bf4e48c8a4f895f1a1d6`, closing issue #20 and
  adding content-checked immutable object references. `ObjectRef` now
  carries path, byte length, and SHA-256 digest; `get_verified` rejects
  length or digest mismatches; table data paths follow
  `{tenant}/{namespace}/tables/{table}/snapshots/{snapshot}/{file}`.
  Current coverage is 46 Rust tests plus Criterion baselines. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `f9f859a`.
- `noetl/ehdb#23` merged on 2026-06-21 as
  `296c5c8bd6fe8605dc1f4852883a7bac994f15bb`, closing issue #22 and
  adding immutable catalog table snapshot metadata over content-checked
  `ObjectRef` file sets. The catalog tracks latest snapshots per table,
  validates linear parent chains, and transaction replay now includes
  `CatalogMutation::CommitSnapshot`. Current coverage is 49 Rust tests
  plus Criterion baselines. `repos/ehdb` should point at this merged
  SHA; `repos/ehdb-wiki` should point at `c5f11c7`.
- `noetl/ehdb#25` merged on 2026-06-21 as
  `784215c0853a35a48cfc0066096ae9b899f21b66`, closing issue #24 and
  adding geo placement plus data-gravity shard pointers to `ObjectRef`.
  `CloudProvider`, `GeoLocation`, `DataGravityShard`, and
  `ObjectPlacement` are now part of `ehdb-storage`; local objects use
  deterministic `local-dev` placement. Treat these as storage-layer
  routing metadata for future distributed placement, replication,
  compaction locality, and read scheduling, while preserving the NoETL
  gateway/worker/playbook boundary. Current coverage is 50 Rust tests
  plus Criterion baselines. `repos/ehdb` should point at this merged
  SHA; `repos/ehdb-wiki` should point at `f13f148`.
- `noetl/ehdb#27` merged on 2026-06-21 as
  `df0029de6fbbbf24bc398a5d33062eefcdf47ff0`, closing issue #26 and
  adding `PlacementRole`, `PlacementTarget`, and `PlacementPolicy`.
  Placement policy validation enforces exactly one primary, minimum copy
  count, one shared data-gravity shard, and no duplicate geo/shard
  targets. This is the metadata contract for future replication planners;
  it does not implement object movement or gateway data-touch behavior.
  Current coverage is 53 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `ebe7a4c`.
- `noetl/ehdb#29` merged on 2026-06-22 as
  `6b3393a696b13e34b84eb2c4d62c44dec4dd4d51`, closing issue #28 and
  adding `ObjectReplica`, `ReplicationAction`, `ReplicationPlan`, and
  `plan_replication`. The planner compares current replicas to
  `PlacementPolicy`, emits already-satisfied and copy-needed actions,
  and rejects source/policy shard mismatch plus replica digest, length,
  or shard mismatch. This remains planner metadata only; no copy
  execution, background worker, or gateway data-touch behavior was
  added. Current coverage is 56 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `289440f`.
- `noetl/ehdb#31` merged on 2026-06-22 as
  `c77ad8ad8786fca9edaa4c2b0ec3fac639553b2a`, closing issue #30 and
  adding durable object replica inventory to the local reference model.
  `InMemoryObjectReplicaRegistry` records object path, length, digest,
  geo placement, and data-gravity shard; rejects conflicting
  digest/length/shard metadata; and feeds replication planning from
  replayed registry state. `StorageMutation::RegisterReplica` makes
  replica inventory replayable through `ehdb-reference` and
  `LocalReferenceRuntime`. This remains metadata only; object-copy
  execution belongs to future bounded worker/playbook steps, not gateway
  behavior. Current coverage is 61 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `8590d47`.
- `noetl/ehdb#33` merged on 2026-06-22 as
  `23227a0833b56abc51c38fb4f7d0c7979d67b7d5`, closing issue #32 and
  adding `LocalReplicationExecutor` in `ehdb-reference`. The executor
  consumes deterministic `ReplicationPlan` values, verifies source bytes
  through `ImmutableObjectStore::get_verified`, and appends
  `StorageMutation::RegisterReplica` transactions through
  `LocalReferenceRuntime` for copy-needed targets. Already-satisfied
  plans are no-ops. This models an atomic future worker/playbook
  replication step; it does not add gateway data-touch logic, long-lived
  schedulers, or cloud transfer adapters. Current coverage is 64 Rust
  tests plus Criterion baselines. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `6f10d1d`.
- `noetl/ehdb#35` merged on 2026-06-22 as
  `b0aa14687357a1032a8f8cff98d8a378d2d7fde8`, closing issue #34 and
  adding `LocalArrowIpcTableStore` in `ehdb-reference`. The fixture
  writes Arrow `RecordBatch` values as immutable IPC objects, commits
  catalog snapshots over content-checked `ObjectRef` values, and reads
  latest snapshots back through verified object reads before Arrow IPC
  decode. Corrupted object bytes are rejected before decode. This proves
  the local Arrow-native catalog/object data path; it does not add Arrow
  Flight service endpoints, distributed query execution, Parquet
  adapters, or gateway direct data access. Current coverage is 66 Rust
  tests plus Criterion baselines. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `1eaa22c`.
- `noetl/ehdb#37` merged on 2026-06-22 as
  `6f271754a83969a30900b8a71266a50978a89047`, closing issue #36 and
  adding `LocalArrowSnapshotScanner` in `ehdb-reference`. The scanner
  resolves latest catalog snapshots, verifies Arrow IPC object bytes
  before decode, returns decoded `RecordBatch` output, and supports
  optional named column projection in caller-specified order. Missing
  projection columns fail deterministically. This is a local scan
  fixture only; predicate pushdown, SQL planning, Arrow Flight,
  distributed execution, and gateway direct data access remain future
  surfaces. Current coverage is 68 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `56283fc`.
- `noetl/ehdb#39` merged on 2026-06-22 as
  `f2100737915650e143fe964c05f207da8964fbc9`, closing issue #38 and
  adding a local Arrow equality-filter fixture to
  `LocalArrowSnapshotScanner`. The scanner now supports single-column
  equality predicates for UTF-8 and Int64 Arrow arrays after verified
  IPC object decode and before optional projection. Missing predicate
  columns and type mismatches fail deterministically. This remains a
  local fixture only; SQL planning, predicate pushdown, Arrow Flight,
  distributed execution, and gateway direct data access remain out of
  scope. Current coverage is 72 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `cd3d2da`.
- `noetl/ehdb#41` merged on 2026-06-22 as
  `51b642f4d8eb60c8971a06f421aa3e6ff8a15374`, closing issue #40 and
  adding the first Phase 4 service-facing scan API boundary. New crate
  `ehdb-service` defines `ScanLatestTableRequest`, `ArrowScanResult`,
  and `LocalArrowScanService` over `LocalArrowSnapshotScanner`, returning
  Arrow schema, record batches, and row count while preserving projection
  and equality-filter behavior. This is pre-network only; Arrow Flight
  server/client code, SQL planning, predicate pushdown, distributed
  execution, and gateway direct reads remain future surfaces. Current
  coverage is 76 Rust tests plus Criterion baselines. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `32cf921`.
- `noetl/ehdb#43` merged on 2026-06-22 as
  `63737eb5786c849c876eae83a1edede393034672`, closing issue #42 and
  adding the Arrow Flight scan ticket codec. `ScanFlightTicket` encodes
  latest-table scan requests into a versioned payload, round-trips
  through Arrow Flight `Ticket` bytes, and builds command
  `FlightDescriptor` values for the future Flight read API. Unsupported
  versions and malformed payloads fail before scan execution. This is a
  contract fixture only; no Flight server/client, SQL planner, predicate
  pushdown, distributed executor, or gateway direct read path was added.
  Current coverage is 82 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `e39776b`.
- `noetl/ehdb#45` merged on 2026-06-22 as
  `0c6688b8e622a5cd0fc1a516388f7f606634e5b8`, closing issue #44 and
  adding the Arrow Flight scan result stream codec. `ArrowScanResult`
  now encodes schema and batches into Arrow Flight `FlightData` messages
  and decodes them back into validated scan results with row counts.
  Empty or malformed streams fail deterministically. This proves the
  local response side of the future Flight `do_get` path without adding
  a Flight server/client, SQL planner, predicate pushdown, distributed
  executor, or gateway direct read path. Current coverage is 86 Rust
  tests plus Criterion baselines. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `b4af436`.
- `noetl/ehdb#47` merged on 2026-06-22 as
  `8ef14058816cb1dd96ee7253d3877aa28246bb66`, closing issue #46 and
  adding the pre-network Arrow Flight scan info fixture.
  `ArrowScanResult::to_flight_info` now builds schema IPC bytes, command
  descriptor, single endpoint ticket, ordered metadata, total record
  count, and encoded byte count from a `ScanFlightTicket` plus local scan
  result. This proves the future `get_flight_info` metadata shape
  without adding a Flight server/client, SQL planner, predicate pushdown,
  distributed executor, or gateway direct read path. Current coverage is
  88 Rust tests plus Criterion baselines. `repos/ehdb` should point at
  this merged SHA; `repos/ehdb-wiki` should point at `fcf6779`.
- `noetl/ehdb#49` merged on 2026-06-22 as
  `0e501004ef01fa45c1b1ce65de93fa5e415b97b0`, closing issue #48 and
  adding the local Arrow Flight scan service facade.
  `LocalArrowFlightService` provides in-process `get_flight_info` from
  typed latest-table scan requests and `do_get` from Arrow Flight
  tickets to `FlightData` streams, reusing `ScanFlightTicket`,
  `ArrowScanResult::to_flight_info`, and
  `ArrowScanResult::to_flight_data`. Malformed tickets fail before scan
  execution and missing-table errors propagate deterministically. This
  remains a local facade only; no Flight network server/client, SQL
  planner, predicate pushdown, distributed executor, or gateway direct
  read path was added. Current coverage is 91 Rust tests plus Criterion
  baselines. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `d4fbad2`.
- `noetl/ehdb#51` merged on 2026-06-22 as
  `42ff431a9d102bf7b8af3f4c9091960b9f28aa73`, closing issue #50 and
  adding the Arrow Flight scan service trait adapter.
  `LocalArrowFlightServer` implements the generated Arrow Flight
  `FlightService` trait for local scan `get_flight_info` and `do_get`,
  decodes command descriptors through `ScanFlightTicket`, streams
  `FlightData`, maps EHDB errors to deterministic gRPC statuses, and
  returns explicit `UNIMPLEMENTED` statuses for non-scan Flight methods.
  This is a trait-level network boundary only; no bound listener,
  persistent server runtime, TLS/auth policy, access-log policy, SQL
  planner, predicate pushdown, distributed executor, or gateway direct
  read path was added. Current coverage is 95 Rust tests plus Criterion
  baselines. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `c0bb1f5`.
- `noetl/ehdb#53` merged on 2026-06-22 as
  `2d9837900aa7c22bd5fff6ac9150d48b75c74289`, closing issue #52 and
  adding bounded Arrow Flight server lifecycle config.
  `LocalArrowFlightServerConfig` validates intended bind address,
  decode/encode message sizes, request concurrency, auth policy, and
  access-log policy before constructing the generated
  `FlightServiceServer` with message limits applied. Defaults are
  loopback-only local reference use, bounded messages, bounded
  concurrency, disabled local auth, and DEBUG-only access logs.
  Unauthenticated non-loopback binds and zero bounds are rejected. This
  adds lifecycle guardrails only; no bound listener, persistent server
  runtime, TLS/auth implementation, request scheduler, SQL planner,
  predicate pushdown, distributed executor, or gateway direct read path
  was added. Current coverage is 99 Rust tests plus Criterion baselines.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki`
  should point at `51d64ee`.
- `noetl/ehdb#55` merged on 2026-06-22 as
  `85ed083c3cb18d7927e2411ab3c3957f555e3c80`, closing issue #54 and
  adding the loopback Arrow Flight listener harness.
  `LocalArrowFlightListener` binds configured or ephemeral loopback
  sockets from `LocalArrowFlightServerConfig`, exposes the actual bound
  local address, serves the generated Arrow Flight service with
  configured message limits, and terminates through an explicit shutdown
  future. Non-loopback listener binds are rejected even when external
  auth policy is selected. This remains a local-reference harness only;
  no non-loopback service exposure, TLS/auth implementation, gateway
  integration, request scheduler, SQL planner, predicate pushdown,
  distributed executor, or gateway direct read path was added. Current
  coverage is 101 Rust tests plus Criterion baselines. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `d21465a`.
- `noetl/ehdb#57` merged on 2026-06-22 as
  `765f216e453cc9e24704bb8c82617388b3574b19`, closing issue #56 and
  adding the loopback Arrow Flight client smoke test.
  The smoke path starts `LocalArrowFlightListener` on loopback, connects
  with Arrow Flight `FlightClient` over tonic/gRPC transport, calls
  `get_flight_info` with the scan command descriptor, follows the
  returned endpoint ticket with `do_get`, and asserts decoded Arrow
  record batches. This is local-reference verification only; no gateway
  integration, non-loopback exposure, TLS/auth implementation, request
  scheduler, SQL planner, predicate pushdown, distributed executor, or
  gateway direct read path was added. Current coverage is 102 Rust tests
  plus Criterion baselines. `repos/ehdb` should point at this merged
  SHA; `repos/ehdb-wiki` should point at `f2d5644`.
- `noetl/ehdb#59` merged on 2026-06-22 as
  `c8a92c081c07a4d30cb990425b29ee168a168449`, closing issue #58 and
  adding the Arrow Flight header-token auth policy contract.
  `FlightAuthPolicy::HeaderToken` validates request metadata header
  names and tokens, `LocalArrowFlightServerConfig` passes the policy
  into the generated service adapter, and implemented scan methods
  `get_flight_info` and `do_get` return deterministic gRPC
  unauthenticated statuses for missing or mismatched metadata. Coverage
  includes direct service tests and a loopback Arrow Flight client smoke
  test with the auth policy enabled. This remains a local-reference
  auth-boundary contract only; no non-loopback exposure, production
  TLS/identity, ACL enforcement, gateway integration, SQL planning,
  predicate pushdown, distributed executor, or gateway direct read path
  was added. Current coverage is 106 Rust tests plus Criterion
  baselines. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `3642685`.
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
