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
- `noetl/ehdb#61` merged on 2026-06-22 as
  `89a069094deb3fbd3b26f25aa593dab39983daba`, closing issue #60 and
  adding the Arrow Flight tenant/namespace scan scope metadata guard.
  `FlightScanScopePolicy` can require `x-ehdb-tenant` and
  `x-ehdb-namespace` metadata to match the decoded
  `ScanLatestTableRequest` before local scan execution. Missing scope
  metadata returns gRPC unauthenticated status; mismatched scope returns
  permission denied. Coverage includes policy validation, generated
  service tests, and a loopback Arrow Flight client smoke test. This is
  a future catalog ACL scope contract only; no ACL engine, non-loopback
  exposure, production TLS/identity, gateway integration, SQL planning,
  predicate pushdown, distributed executor, or gateway direct read path
  was added. Current coverage is 110 Rust tests plus Criterion
  baselines. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `c79d1e6`.
- `noetl/ehdb#63` merged on 2026-06-22 as
  `f13258a8c829bdc2950fd1a1f9ec2c970a99df32`, closing issue #62 and
  adding the first catalog-side scan grant reference model.
  `PrincipalId` is now a typed EHDB identifier. `CatalogScanGrant`
  records tenant, namespace, table ID, principal, and granting
  transaction ID; `InMemoryCatalog::can_scan` answers table/principal
  scan access; and `CatalogMutation::GrantScan` makes the metadata
  replayable through `ehdb-reference` and `LocalReferenceRuntime`.
  This is durable catalog ACL metadata only; no production IAM, policy
  composition, revocation, service enforcement, non-loopback exposure,
  gateway integration, SQL planning, predicate pushdown, distributed
  executor, or gateway direct read path was added. Current coverage is
  113 Rust tests plus Criterion baselines. `repos/ehdb` should point at
  this merged SHA; `repos/ehdb-wiki` should point at `d9deca7`.
- `noetl/ehdb#65` merged on 2026-06-22 as
  `8bd1aace3ddc33911fb8ede47fc6822532cb282c`, closing issue #64 and
  enforcing replayed catalog scan grants in the local Arrow Flight
  reference path. `FlightScanGrantPolicy` can require
  `x-ehdb-principal` metadata, validate it as a `PrincipalId`, resolve
  the requested table from replayed catalog state, and call
  `InMemoryCatalog::can_scan` before `get_flight_info` or `do_get`
  reaches the local scanner. Missing or invalid principal metadata
  returns gRPC unauthenticated status; principals without a replayed
  `CatalogScanGrant` return permission denied. Coverage includes direct
  generated-service tests and a loopback Arrow Flight client smoke test.
  This is local reference enforcement only; no production IAM, policy
  composition, revocation, non-loopback exposure, gateway integration,
  SQL planning, predicate pushdown, distributed executor, or gateway
  direct read path was added. Current coverage is 117 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `eb3b7ec`.
- `noetl/ehdb#67` merged on 2026-06-22 as
  `0bce4ae6ca18f678bbe580bbee8f4b1e4b51850e`, closing issue #66 and
  adding bounded local Arrow Flight scan access summaries.
  `FlightAccessLogPolicy` now controls disabled and DEBUG-only access
  summary modes for decoded `get_flight_info` and `do_get` requests.
  The summary contract includes method, gRPC code, row/message counts,
  projection count, predicate presence, and which metadata guards were
  required; it excludes auth tokens, principal values, tenant/table
  identifiers, object paths, predicate values, and Arrow payloads.
  This is local reference observability only; no non-loopback exposure,
  production IAM, gateway integration, SQL planning, predicate pushdown,
  distributed executor, gateway direct read path, high-volume INFO logs,
  tenant data logging, or persistent per-tenant service process was
  added. Current coverage is 120 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `ae13d05`.
- `noetl/ehdb#69` merged on 2026-06-22 as
  `154c265cc328ca05dd41a831a41cc134cddc03a5`, closing issue #68 and
  adding local Arrow Flight `get_schema` support for scan command
  descriptors. `LocalArrowFlightService::get_schema` returns projected
  latest-table scan schemas as Arrow Flight `SchemaResult` values, and
  generated `FlightService::get_schema` now uses the same auth,
  tenant/namespace scan scope, catalog scan grant, and bounded access-log
  policies as `get_flight_info` and `do_get`. The loopback Flight client
  smoke path now calls `FlightClient::get_schema` before data reads.
  This is local reference schema discovery only; no non-loopback
  exposure, production IAM, gateway integration, SQL planning, predicate
  pushdown, distributed executor, gateway direct read path, request
  scheduler, or persistent per-tenant service process was added. Current
  coverage remains 120 Rust tests plus Criterion benchmark compilation.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki` should
  point at `5c22f65`.
- `noetl/ehdb#71` merged on 2026-06-22 as
  `76622a7d38911f222bb11cdb9f5b37ef00565c17`, closing issue #70 and
  enforcing the local Arrow Flight request concurrency budget.
  `LocalArrowFlightServerConfig::max_concurrent_requests` now feeds a
  fail-fast semaphore in `LocalArrowFlightServer`; implemented scan
  methods `get_flight_info`, `get_schema`, and `do_get` return gRPC
  `RESOURCE_EXHAUSTED` when all local request slots are occupied.
  Existing constructors retain the default local-reference budget.
  This is a local lifecycle guard only; no request queue, distributed
  admission controller, non-loopback exposure, production IAM, gateway
  integration, SQL planning, predicate pushdown, distributed executor,
  gateway direct read path, or persistent per-tenant service process was
  added. Current coverage is 121 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `f4deb46`.
- `noetl/ehdb#73` merged on 2026-06-22 as
  `45243ef9a426e707ae165b07e1607a24ecca2760`, closing issue #72 and
  adding the first local retrieval vector similarity fixture.
  `VectorSearch` and `VectorSearchHit` provide an exact cosine-similarity
  boundary over registered chunk embeddings, scoped by tenant,
  namespace, and embedding model. The fixture validates finite non-zero
  embedding and query vectors, applies dimension compatibility, and
  orders hits deterministically. This is a local RAG correctness
  primitive only; no ANN index, retrieval daemon, production IAM,
  gateway integration, external Qdrant adapter, distributed query
  engine, gateway direct data path, or persistent per-tenant service
  process was added. Current coverage is 124 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `d464c02`.
- `noetl/ehdb#75` merged on 2026-06-22 as
  `c6224be27b6df65c021fafad3a45c2954525604e`, closing issue #74 and
  adding the local retrieval vector search service boundary.
  `LocalRetrievalSearchService` in `ehdb-service` wraps replayed
  `LocalReferenceRuntime` retrieval state with typed
  `SearchSimilarChunksRequest` and `SearchSimilarChunksHit` values,
  returning ranked chunk/document/text/checksum/model/dimension/score
  results while excluding raw embedding vectors. This remains an
  in-process worker/playbook-oriented reference boundary only; no
  network service, gateway route, production IAM, ANN index, external
  Qdrant adapter, distributed query engine, retrieval daemon, gateway
  direct data path, or persistent per-tenant service process was added.
  Current coverage is 126 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `d9053d9`.
- `noetl/ehdb#77` merged on 2026-06-22 as
  `8b853e5de110d15e4c9aae72bc12bd114609eb9f`, closing issue #76 and
  adding the local retrieval text search boundary. `TextSearch` and
  `TextSearchHit` in `ehdb-retrieval` provide exact case-insensitive
  substring matching scoped by tenant and namespace, with positive-limit
  validation, non-empty query validation, match counts, and deterministic
  ordering. `LocalRetrievalSearchService::search_text` exposes the same
  replayed-state behavior through `SearchTextChunksRequest` and
  `SearchTextChunksHit`. This remains an in-process RAG correctness
  boundary only; no full-text index, BM25 engine, network service,
  gateway route, production IAM, external search adapter, distributed
  query engine, retrieval daemon, gateway direct data path, or
  persistent per-tenant service process was added. Current coverage is
  130 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `4fa4165`.
- `noetl/ehdb#79` merged on 2026-06-23 UTC as
  `3d58042a8fc173414dae149296f68f26dac45672`, closing issue #78 and
  adding the local retrieval hybrid search boundary. `HybridSearch` and
  `HybridSearchHit` in `ehdb-retrieval` combine exact cosine similarity
  and exact case-insensitive text match counts with finite non-negative
  weights, positive-limit validation, vector validation, replayed
  tenant/namespace/model scoping, zero-score filtering, and deterministic
  ordering. `LocalRetrievalSearchService::search_hybrid` exposes the
  same replayed-state behavior through `SearchHybridChunksRequest` and
  `SearchHybridChunksHit`. This remains an in-process RAG correctness
  boundary only; no ANN index, BM25 engine, learned ranker, network
  service, gateway route, production IAM, external search adapter,
  distributed query engine, retrieval daemon, gateway direct data path,
  or persistent per-tenant service process was added. Current coverage
  is 135 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `f5ade08`.
- `noetl/ehdb#81` merged on 2026-06-23 UTC as
  `fccbbe19e1046dadb6323bdafa26230cd4512c11`, closing issue #80 and
  adding the local retrieval context assembly boundary.
  `AssembleRetrievalContextRequest`, `RetrievalContextBlock`, and
  `RetrievalContext` in `ehdb-service` build bounded RAG context blocks
  from replayed local hybrid search hits. The boundary preserves chunk
  identity, document identity, ordinal, checksum, clipped text,
  original text length, model metadata, vector score, text match count,
  combined score, total text budget accounting, and truncation metadata
  without returning raw embedding vectors. It validates positive block
  and total text budgets and inherits hybrid search validation for
  positive hit limits, vector inputs, text query, and weights. This
  remains an in-process worker/playbook-shaped correctness boundary
  only; no ANN index, BM25 engine, learned ranker, prompt template
  engine, LLM invocation, network service, gateway route, production
  IAM, external search adapter, distributed query engine, retrieval
  daemon, gateway direct data path, or persistent per-tenant service
  process was added. Current coverage is 139 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `15301e2`.
- `noetl/ehdb#83` merged on 2026-06-23 UTC as
  `41ab8357e37255cf2668b998f0f728787c256e47`, closing issue #82 and
  adding the local retrieval context payload codec.
  `RetrievalContextRequestPayload` and `RetrievalContextResultPayload`
  in `ehdb-service` wrap context assembly requests/results in explicit
  versioned JSON byte payloads. The codec derives serialization for
  `AssembleRetrievalContextRequest`, `RetrievalContextBlock`, and
  `RetrievalContext`, round-trips request/result payloads, and rejects
  malformed JSON or unsupported request/result versions
  deterministically before execution or handoff. This remains a local
  worker/playbook payload boundary only; no network API, Arrow Flight
  retrieval endpoint, prompt template engine, LLM invocation, ANN index,
  BM25 engine, learned ranker, gateway route, production IAM, retrieval
  daemon, distributed query engine, gateway direct data path, or
  persistent per-tenant service process was added. Current coverage is
  143 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `3ae0c70`.
- `noetl/ehdb#85` merged on 2026-06-23 UTC as
  `9c494f9dd1879e6694a4dc3d0fad122f54601139`, closing issue #84 and
  adding the local retrieval context payload executor.
  `LocalRetrievalSearchService::execute_context_payload` in
  `ehdb-service` decodes versioned retrieval context request payload
  bytes, assembles context from replayed `LocalReferenceRuntime`
  retrieval state, and returns a versioned result payload. It
  propagates malformed payload, unsupported version, and invalid
  search/budget errors deterministically, and covers happy-path payload
  execution plus empty-result payloads. This remains an in-process
  worker/playbook payload executor only; no network API, Arrow Flight
  retrieval endpoint, prompt template engine, LLM invocation, ANN index,
  BM25 engine, learned ranker, gateway route, production IAM, retrieval
  daemon, distributed query engine, gateway direct data path, or
  persistent per-tenant service process was added. Current coverage is
  146 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `817bb1f`.
- `noetl/ehdb#87` merged on 2026-06-23 UTC as
  `854dae3417ec182313666f022059c62286c86fbb`, closing issue #86 and
  adding bounded local retrieval context payload execution.
  `RetrievalContextPayloadExecutorConfig` in `ehdb-service` validates
  positive request/result byte limits, supplies conservative defaults,
  and powers `LocalRetrievalSearchService::execute_context_payload_with_config`.
  Oversized request payloads are rejected before JSON decode and
  oversized encoded result payloads are rejected before returning bytes,
  while the existing convenience executor uses the default config. This
  remains an in-process worker/playbook payload guard only; no network
  API, Arrow Flight retrieval endpoint, prompt template engine, LLM
  invocation, ANN index, BM25 engine, learned ranker, gateway route,
  production IAM, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added. Current coverage is 150 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `7c0073c`.
- `noetl/ehdb#89` merged on 2026-06-23 UTC as
  `b2c36d111921b8e1ba7bc491aaa47dd61cefecad`, closing issue #88 and
  adding the local retrieval context payload scope guard.
  `RetrievalContextPayloadScope` in `ehdb-service` validates decoded
  context assembly requests against an expected tenant and namespace
  before context assembly. `LocalRetrievalSearchService::execute_context_payload_with_scope`
  composes existing byte bounds with that local scope check while
  leaving default and config-aware payload execution unchanged. This
  remains an in-process worker/playbook correctness guard only; no
  production IAM, policy engine, ACL integration, network API, Arrow
  Flight retrieval endpoint, prompt template engine, LLM invocation,
  ANN index, BM25 engine, learned ranker, gateway route, retrieval
  daemon, distributed query engine, gateway direct data path, scheduler,
  or persistent per-tenant service process was added. Current coverage
  is 153 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `40d3805`.
- `noetl/ehdb#91` merged on 2026-06-23 UTC as
  `98508dd15a7bb50bb5c2296da19a31a826808610`, closing issue #90 and
  adding redacted local retrieval context execution summaries.
  `RetrievalContextPayloadExecutionSummary` in `ehdb-service` reports
  request/result byte counts, context block count, total text chars,
  truncation status, and whether a local scope guard was required.
  Summary-returning default, config-aware, and scope-aware executor APIs
  now return `RetrievalContextPayloadExecution`, while existing
  byte-returning APIs delegate through that path and remain
  behavior-compatible. The summary intentionally excludes tenant IDs,
  namespace values, query text, chunk text, tokens, embedding vectors,
  payload bytes, object paths, and principals. This remains redacted
  metrics/audit metadata for local worker/playbook tests only; no
  logging sink, network API, Arrow Flight retrieval endpoint, prompt
  engine, LLM invocation, ANN index, BM25 engine, learned ranker,
  gateway route, production IAM, ACL integration, retrieval daemon,
  distributed query engine, gateway direct data path, scheduler, or
  persistent per-tenant service process was added. Current coverage is
  157 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `de4fa24`.
- `noetl/ehdb#93` merged on 2026-06-23 UTC as
  `c997be8a32bb737a12579c16dfab30c2c4da1f8d`, closing issue #92 and
  adding the redacted retrieval context execution receipt codec.
  `RetrievalContextPayloadExecutionReceiptPayload` in `ehdb-service`
  wraps `RetrievalContextPayloadExecutionSummary` in a versioned JSON
  byte payload for future durable event-log/audit plumbing. The receipt
  round-trips only the redacted summary fields, rejects malformed JSON
  and unsupported versions deterministically, and tests prove encoded
  receipts exclude tenant IDs, namespace values, query text, chunk
  text, tokens, embedding vectors, payload bytes, object paths, and
  principals. Existing retrieval context payload executor behavior is
  unchanged. This remains a durable receipt shape for local
  worker/playbook tests only; no event publication, stream mutation,
  logging sink, network API, Arrow Flight retrieval endpoint, prompt
  engine, LLM invocation, ANN index, BM25 engine, learned ranker,
  gateway route, production IAM, ACL integration, retrieval daemon,
  distributed query engine, gateway direct data path, scheduler, or
  persistent per-tenant service process was added. Current coverage is
  160 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `a2467a0`.
- `noetl/ehdb#95` merged on 2026-06-23 UTC as
  `b5c9e23e92e32d179728ea0105274060c686f97f`, closing issue #94 and
  adding the local retrieval context execution receipt helper.
  `RetrievalContextPayloadExecution::encode_receipt_payload` in
  `ehdb-service` emits versioned
  `RetrievalContextPayloadExecutionReceiptPayload` bytes directly from
  the redacted summary attached to a local execution result. Tests prove
  helper-produced receipts decode back to the same summary and preserve
  the redaction boundary for tenant IDs, namespace values, query text,
  chunk text, tokens, embedding vectors, payload bytes, object paths,
  and principals. Existing executor and receipt codec behavior is
  unchanged. This remains local worker/playbook helper wiring only; no
  event publication, stream mutation, logging sink, network API, Arrow
  Flight retrieval endpoint, prompt engine, LLM invocation, ANN index,
  BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added. Current coverage is 162 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `5c64c20`.
- `noetl/ehdb#97` merged on 2026-06-23 UTC as
  `8fff5535f2e13de9b322bdd6fe6b514e8cdad132`, closing issue #96 and
  adding validation for retrieval context execution receipt summaries.
  `RetrievalContextPayloadExecutionSummary::validate` now requires
  positive request/result payload byte counts and rejects non-zero total
  text chars when the context block count is zero. The receipt codec
  applies this validation during both encode and decode, while
  execution-produced and helper-produced receipts remain
  behavior-compatible. This remains local receipt contract hardening
  only; no event publication, stream mutation, logging sink, network
  API, Arrow Flight retrieval endpoint, prompt engine, LLM invocation,
  ANN index, BM25 engine, learned ranker, gateway route, production
  IAM, ACL integration, retrieval daemon, distributed query engine,
  gateway direct data path, scheduler, or persistent per-tenant service
  process was added. Current coverage is 165 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `aaa6335`.
- `noetl/ehdb#99` merged on 2026-06-23 UTC as
  `c0613881814643cf284bf0ee24f3d7cfb43444a3`, closing issue #98 and
  adding bounded retrieval context execution artifacts.
  `RetrievalContextPayloadExecutionArtifacts` in `ehdb-service` returns
  result payload bytes together with redacted receipt payload bytes for
  local worker/playbook handoff tests. `RetrievalContextPayloadExecutorConfig`
  now includes `max_receipt_payload_bytes`, with positive validation,
  and artifact helpers enforce that bound after the existing
  request/result execution path succeeds. Existing byte-returning,
  summary-returning, scope, and receipt APIs remain behavior-compatible.
  This remains local helper wiring only; no event publication, stream
  mutation, logging sink, network API, Arrow Flight retrieval endpoint,
  prompt engine, LLM invocation, ANN index, BM25 engine, learned ranker,
  gateway route, production IAM, ACL integration, retrieval daemon,
  distributed query engine, gateway direct data path, scheduler, or
  persistent per-tenant service process was added. Current coverage is
  168 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `235229b`.
- `noetl/ehdb#101` merged on 2026-06-23 UTC as
  `b87e4b41af872a5f82661700a5ac4c56f6ec4873`, closing issue #100 and
  validating retrieval context execution artifact consistency.
  `RetrievalContextPayloadExecutionArtifacts::receipt_summary` decodes
  the redacted receipt payload through the existing receipt codec, and
  `RetrievalContextPayloadExecutionArtifacts::validate` rejects empty
  result/receipt payloads, malformed receipts, and artifacts whose
  receipt summary result byte count does not match the actual result
  payload length. Artifact helper paths now return validated artifacts.
  This remains local artifact contract hardening only; no event
  publication, stream mutation, logging sink, network API, Arrow Flight
  retrieval endpoint, prompt engine, LLM invocation, ANN index, BM25
  engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added. Current coverage is 171 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `359f581`.
- `noetl/ehdb#103` merged on 2026-06-23 UTC as
  `cebcf2f2ee2116e8559327a33332009eb93a5ca9`, closing issue #102 and
  adding a local stream-ready retrieval context receipt event payload.
  `RetrievalContextPayloadExecutionReceiptEventPayload` wraps validated
  redacted receipt bytes in a versioned JSON event envelope with stable
  subject `ehdb.retrieval.context.execution.receipt`. Artifact helpers
  can build and encode this event payload from validated
  `RetrievalContextPayloadExecutionArtifacts`; decode validates the
  embedded receipt through the existing receipt codec and rejects empty
  receipt bytes, malformed receipts, and unsupported event envelope
  versions. The event envelope deliberately excludes result
  payload/context bytes and remains local modeling only; no automatic
  stream publication, stream mutation, logging sink, network API, Arrow
  Flight retrieval endpoint, prompt engine, LLM invocation, ANN index,
  BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added. Current coverage is 174 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `2feaf2d`.
- `noetl/ehdb#105` merged on 2026-06-23 UTC as
  `0d2c1bed33d43b0a541c7335c6be79795054d613`, closing issue #104 and
  adding an explicit local retrieval receipt event stream publisher.
  `RetrievalContextReceiptEventStreamTarget` captures caller-owned
  tenant, namespace, and stream name, while
  `RetrievalContextReceiptEventStreamLog` publishes validated
  `RetrievalContextPayloadExecutionReceiptEventPayload` values to
  caller-supplied `InMemoryStreamLog` or `LocalJsonlStreamLog` with
  stable subject `ehdb.retrieval.context.execution.receipt` and a
  caller-supplied transaction id. Tests cover in-memory publish/replay,
  JSONL persist/reopen/replay, missing stream errors, and malformed
  artifact rejection. This remains explicit local worker/playbook
  publication only; no automatic stream publication, background task,
  logging sink, network API, Arrow Flight retrieval endpoint, prompt
  engine, LLM invocation, ANN index, BM25 engine, learned ranker,
  gateway route, production IAM, ACL integration, retrieval daemon,
  distributed query engine, gateway direct data path, scheduler, or
  persistent per-tenant service process was added. Current coverage is
  177 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `f1f195f`.
- `noetl/ehdb#107` merged on 2026-06-23 UTC as
  `95d147df5721e943f41ab8efe1ad327cb541d3be`, closing issue #106 and
  adding explicit local retrieval receipt event stream replay decoding.
  `RetrievalContextReceiptEventStreamRecord` carries stream sequence,
  transaction id, and a validated
  `RetrievalContextPayloadExecutionReceiptEventPayload`.
  `RetrievalContextReceiptEventStreamReadLog` replays raw records from
  caller-supplied `InMemoryStreamLog` or `LocalJsonlStreamLog`, and
  `RetrievalContextReceiptEventStreamTarget::replay_events` validates
  the stable subject `ehdb.retrieval.context.execution.receipt` plus
  the event payload while preserving cursor behavior. Tests cover
  ordered replay, cursor replay, JSONL reopen/replay, wrong subject
  rejection, and malformed payload rejection. This remains explicit
  local worker/playbook replay only; no background consumer,
  subscription loop, automatic processing, logging sink, network API,
  Arrow Flight retrieval endpoint, prompt engine, LLM invocation, ANN
  index, BM25 engine, learned ranker, gateway route, production IAM,
  ACL integration, retrieval daemon, distributed query engine, gateway
  direct data path, scheduler, or persistent per-tenant service process
  was added. Current coverage is 180 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `4ae9ed8`.
- `noetl/ehdb#109` merged on 2026-06-23 UTC as
  `ff12df09cdd3f9c4398a813bb88b7d2c4ac4c8e8`, closing issue #108 and
  adding explicit local durable-consumer helpers for retrieval receipt
  event streams. `RetrievalContextReceiptEventDurableConsumerLog`
  supports caller-controlled durable consumer creation, replaying
  pending validated receipt events for a consumer, and acking receipt
  event sequences for caller-supplied `InMemoryStreamLog` and
  `LocalJsonlStreamLog` instances. The cursor is advanced only by
  explicit caller ack, with replay still validating the stable subject
  `ehdb.retrieval.context.execution.receipt` and receipt event payload.
  Tests cover consumer resume/ack behavior, ack rollback rejection,
  missing consumer rejection, and JSONL reopen cursor behavior. This
  remains explicit local worker/playbook consumer control only; no
  background consumer, subscription loop, scheduler, automatic
  processing, logging sink, network API, Arrow Flight retrieval
  endpoint, prompt engine, LLM invocation, ANN index, BM25 engine,
  learned ranker, gateway route, production IAM, ACL integration,
  retrieval daemon, distributed query engine, gateway direct data path,
  or persistent per-tenant service process was added. Current coverage
  is 183 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `8bbfa38`.
- `noetl/ehdb#111` merged on 2026-06-23 UTC as
  `da4ebfb98667bde853715d4aa2588b528567fb6d`, closing issue #110 and
  adding explicit local receipt event stream setup helpers.
  `RetrievalContextReceiptEventStreamTarget::stream_config` builds
  `StreamConfig` from target tenant, namespace, stream, and
  caller-selected retention policy, while
  `RetrievalContextReceiptEventStreamTarget::create_stream` creates
  the receipt event stream through caller-supplied `InMemoryStreamLog`
  or `LocalJsonlStreamLog` instances. Publish helpers still do not
  auto-create streams. Tests cover setup plus publish/replay, duplicate
  stream rejection, and JSONL stream persistence after reopen. This
  remains explicit local worker/playbook stream setup only; no
  auto-create-on-publish, scheduler, automatic processing, logging
  sink, network API, Arrow Flight retrieval endpoint, prompt engine, LLM
  invocation, ANN index, BM25 engine, learned ranker, gateway route,
  production IAM, ACL integration, retrieval daemon, distributed query
  engine, gateway direct data path, or persistent per-tenant service
  process was added. Current coverage is 186 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `8126c35`.
- `noetl/ehdb#113` merged on 2026-06-23 UTC as
  `c9f67cff0645edab2295a8c92b5e317adff84b5c`, closing issue #112 and
  adding explicit bounded retention setup helpers for retrieval receipt
  event streams. `RetrievalContextReceiptEventStreamTarget` now has
  `create_keep_all_stream` and `create_bounded_stream`; the bounded
  helper rejects zero retention before touching the stream log and then
  creates a stream with `RetentionPolicy::MaxRecords`. Tests cover
  bounded retention replay behavior, zero-bound rejection, and JSONL
  bounded stream persistence after reopen. This remains explicit local
  worker/playbook stream setup only; no auto-create-on-publish,
  scheduler, automatic processing, logging sink, network API, Arrow
  Flight retrieval endpoint, prompt engine, LLM invocation, ANN index,
  BM25 engine, learned ranker, gateway route, production IAM, ACL
  integration, retrieval daemon, distributed query engine, gateway
  direct data path, or persistent per-tenant service process was added.
  Current coverage is 189 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `1518d62`.
- `noetl/ehdb#115` merged on 2026-06-23 UTC as
  `b70cf038acd4c9ec2455c2b24aacad021bf3c247`, closing issue #114 and
  enforcing positive bounded stream retention at the stream log
  boundary. `InMemoryStreamLog::create_stream` and
  `LocalJsonlStreamLog::create_stream` now reject
  `RetentionPolicy::MaxRecords(0)` with `EhdbError::InvalidState`.
  JSONL setup validates before writing a journal entry, so rejected
  zero-retention streams are not persisted across reopen. Keep-all and
  positive bounded retention behavior is unchanged. This remains local
  stream log validation only; no scheduler, background stream
  processing, NATS bridge, network API, gateway route, distributed
  stream storage, production replication, or persistent per-tenant
  service process was added. Current coverage is 191 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `b4cee2b`.
- `noetl/ehdb#117` merged on 2026-06-23 UTC as
  `70c33dc30467e6ac08f59c95b6f556074cfedc2a`, closing issue #116 and
  adding explicit subject-filtered replay for local EHDB stream logs.
  `Subject::matches` now supports exact subject matching, single-token
  `*` wildcards, and terminal `>` tail wildcards while misplaced `>`
  filters do not match unrelated subjects. `InMemoryStreamLog` and
  `LocalJsonlStreamLog` expose `replay_matching` to return retained
  stream records after an optional cursor and subject filter. Tests
  cover exact matching, wildcard matching, cursor behavior, and JSONL
  reopen behavior. This remains local explicit stream-log replay only;
  no durable subject subscription, scheduler, background stream
  processing, NATS bridge, network API, gateway route, distributed
  stream storage, production replication, or persistent per-tenant
  service process was added. Current coverage is 194 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `f4d98e9`.
- `noetl/ehdb#119` merged on 2026-06-23 UTC as
  `2062560d3b6af3929c02230f4846c16ff90a8719`, closing issue #118 and
  adding explicit subject-filtered durable consumer replay for local
  EHDB stream logs. `InMemoryStreamLog` and `LocalJsonlStreamLog` now
  expose `replay_matching_for_consumer`, which filters records pending
  after the durable consumer ack cursor by subject without moving that
  cursor. Missing consumers still return `EhdbError::NotFound`. Tests
  cover wildcard filtering, cursor behavior, missing consumers, and
  JSONL reopen behavior. This remains local explicit stream-log replay
  only; no durable subject subscription, scheduler, background stream
  processing, NATS bridge, network API, gateway route, distributed
  stream storage, production replication, or persistent per-tenant
  service process was added. Current coverage is 196 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `9c154c4`.
- `noetl/ehdb#121` merged on 2026-06-23 UTC as
  `8031f94d8c93cb2c5b2b72eb96b87d54780c5e72`, closing issue #120 and
  separating concrete stream subjects from wildcard subject filters.
  `Subject::new` now rejects wildcard tokens `*` and `>` for published
  stream record subjects. New `SubjectFilter` values support exact
  selectors, single-token `*` wildcards, and terminal `>` tail
  wildcards for replay selectors; misplaced `>` and partial wildcard
  tokens are rejected at construction. Filtered replay APIs now accept
  `SubjectFilter` instead of concrete `Subject`. This remains local
  stream log validation and replay only; no durable subject
  subscription, scheduler, background stream processing, NATS bridge,
  network API, gateway route, distributed stream storage, production
  replication, or persistent per-tenant service process was added.
  Current coverage is 196 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `9c37613`.
- `noetl/ehdb#123` merged on 2026-06-23 UTC as
  `17c1644994cc39f97d1e29d40174cd2c2e4f547e`, closing issue #122 and
  rejecting empty dot-delimited stream subject tokens. `Subject::new`
  and `SubjectFilter::new` now reject leading, trailing, and double-dot
  empty tokens while preserving valid concrete subjects and valid
  exact/wildcard filters. This remains local stream log validation only;
  no durable subject subscription, scheduler, background stream
  processing, NATS bridge, network API, gateway route, distributed
  stream storage, production replication, or persistent per-tenant
  service process was added. Current coverage is 196 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `7bb4f29`.
- `noetl/ehdb#125` merged on 2026-06-23 UTC as
  `fe848a525dfece16ba7ad5662c277d3b1a03a3a0`, closing issue #124 and
  validating persisted stream record subjects during local JSONL journal
  replay. Replayed publish entries now re-run
  `Subject::new(record.subject.as_str())` before insertion, so wildcard
  concrete subjects and empty-token subjects deserialized from JSONL are
  rejected instead of rebuilding invalid state. This remains local stream
  journal replay validation only; no durable subject subscription,
  scheduler, background stream processing, NATS bridge, network API,
  gateway route, distributed stream storage, production replication, or
  persistent per-tenant service process was added. Current coverage is
  198 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `c628ee1`.
- `noetl/ehdb#127` merged on 2026-06-23 UTC as
  `97c4cd67a76f61e184a78596507ebbf7daaa4fe5`, closing issue #126 and
  validating persisted stream journal identifiers during local JSONL
  replay. Replayed stream config, create-consumer, publish, and ack
  entries now re-run tenant/namespace/stream coordinate validation;
  consumer names and stream record transaction IDs are also revalidated
  before rebuilding retained records or consumer cursor state. Invalid
  persisted identifiers fail reopen deterministically with
  `EhdbError::InvalidIdentifier` instead of rebuilding invalid state or
  surfacing as misleading missing-stream errors. This remains local
  stream journal replay validation only; no durable subject
  subscription, scheduler, background stream processing, NATS bridge,
  network API, gateway route, distributed stream storage, production
  replication, or persistent per-tenant service process was added.
  Current coverage is 202 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `252e425`.
- `noetl/ehdb#129` merged on 2026-06-23 UTC as
  `5aa284228eecb877f36e02d701da1168ce4aaa55`, closing issue #128 and
  validating persisted transaction journal identifiers during local
  JSONL replay. Replayed transaction envelopes now re-run transaction
  ID, tenant, and namespace validation; catalog, stream, retrieval,
  system-library, and storage mutation identifiers are also revalidated
  before insertion. Stream publish subjects inside transaction mutations
  are revalidated as concrete subjects, and corrupted persisted
  transaction records fail reopen deterministically instead of entering
  ordered replay state. This remains local transaction-log replay
  validation only; no consensus engine, background processing, network
  API, gateway data-touch behavior, production replication, scheduler
  behavior, or persistent per-tenant service process was added. Current
  coverage is 208 Rust tests plus Criterion benchmark compilation.
  `repos/ehdb` should point at this merged SHA; `repos/ehdb-wiki`
  should point at `e32cd7c`.
- `noetl/ehdb#131` merged on 2026-06-23 UTC as
  `243d78eb41cb1f7f33426147203a33c3afd40e64`, closing issue #130 and
  validating persisted system-library journal identifiers during local
  JSONL replay. Replayed publish entries now revalidate library path,
  revision, digest, object path, and transaction ID before rebuilding
  immutable WASM manifests. Replayed bind entries revalidate tenant,
  namespace, environment, channel, path, revision, digest, and
  transaction ID before rebuilding hot-replaceable environment/channel
  bindings. This remains local system-library journal replay validation
  only; no WASM execution, background processing, network API, gateway
  data-touch behavior, production replication, scheduler behavior, or
  persistent per-tenant service process was added. Current coverage is
  210 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `6c95770`.
- `noetl/ehdb#133` merged on 2026-06-23 UTC as
  `4261d3ed8d4039b33d53a4241d18cb78b11368f5`, closing issue #132 and
  validating retrieval context payload identifiers during local RAG
  payload encode/decode. `RetrievalContextRequestPayload` now
  revalidates tenant, namespace, and embedding model identifiers;
  `RetrievalContextResultPayload` revalidates chunk, document, and
  embedding model identifiers for each context block. Invalid decoded
  identifiers fail before worker/playbook execution or handoff. This
  remains local RAG payload codec validation only; no ANN index,
  retrieval daemon, RPC protocol, Arrow Flight retrieval endpoint,
  gateway data-touch behavior, prompt/LLM invocation, background
  processing, scheduler behavior, or persistent per-tenant service
  process was added. Current coverage is 212 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `55c0fa5`.
- `noetl/ehdb#135` merged on 2026-06-23 UTC as
  `2e18c2190e221efc5d9e9503b79c2f97222afbdd`, closing issue #134 and
  validating Arrow Flight scan ticket identifiers during local scan
  ticket encode/decode. `ScanFlightTicket` now revalidates tenant,
  namespace, and table-name identifiers before producing bytes, Arrow
  `Ticket` values, or command descriptors, and after decoding ticket
  bytes. Invalid decoded identifiers fail before local scan execution.
  This remains local Arrow Flight scan ticket codec validation only; no
  SQL planner, predicate pushdown, distributed execution, gateway direct
  reads, non-loopback exposure, production auth/IAM, background
  processing, or persistent per-tenant service process was added.
  Current coverage is 213 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `001cea2`.
- `noetl/ehdb#137` merged on 2026-06-24 UTC as
  `f318fcb4a8978a718be2094245c8c672ab611ea4`, closing issue #136 and
  validating Arrow Flight scan selector identifiers during local scan
  ticket encode/decode. `ScanFlightTicket` now revalidates
  projection-column and equality-predicate column identifiers before
  producing bytes, Arrow `Ticket` values, or command descriptors, and
  after decoding ticket bytes. Invalid decoded selector identifiers fail
  before local scan execution. This remains local Arrow Flight scan
  ticket codec validation only; no SQL planner, predicate pushdown
  implementation, distributed execution, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  214 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `b6cf9a9`.
- `noetl/ehdb#139` merged on 2026-06-24 UTC as
  `5bd6982fabde4f355e96f64b50f633006f70127e`, closing issue #138 and
  validating Arrow Flight scan result stream metadata during local
  result stream encode/decode. `ArrowScanResult` now stamps produced
  `FlightData` streams with `ehdb.arrow.scan.result.v1`, aligns
  `FlightInfo` app metadata to that result-stream version, and rejects
  empty, missing-version, unsupported-version, or malformed streams
  before accepting decoded Arrow batches. This remains local Arrow
  Flight scan result stream codec validation only; no Flight protocol
  expansion, distributed execution, SQL planner, predicate pushdown
  implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 215 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `44150fe`.
- `noetl/ehdb#141` merged on 2026-06-24 UTC as
  `72abdb7d29cca0c9bb38e90a3c672691b45093ac`, closing issue #140 and
  enforcing a strict Arrow Flight scan result metadata envelope during
  local result stream decode. `ArrowScanResult` now accepts the
  `ehdb.arrow.scan.result.v1` marker only on the first `FlightData`
  message, keeps locally produced later-message app metadata empty, and
  rejects non-empty later-message app metadata before Arrow decode. This
  remains local Arrow Flight scan result stream codec validation only;
  no Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added. Current coverage is 216 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `1c8fd47`.
- `noetl/ehdb#143` merged on 2026-06-24 UTC as
  `5a1954eb81565015e6f956586632d91d0d84c2af`, closing issue #142 and
  adding local Arrow Flight scan `FlightInfo` fixture validation.
  `ArrowScanResult::to_flight_info` now validates generated fixtures,
  and `ArrowScanResult::validate_flight_info` rejects unsupported app
  metadata, unordered scan results, negative record or byte counts,
  missing endpoint tickets, and multiple endpoints while reusing the
  scan ticket validation boundary for descriptors and endpoint tickets.
  This remains local Arrow Flight scan `FlightInfo` fixture validation
  only; no Flight protocol expansion, distributed execution, SQL
  planner, predicate pushdown implementation, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  217 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `bb0ae68`.
- `noetl/ehdb#145` merged on 2026-06-24 UTC as
  `c86fb397210e6de73ecea17f13c74a3127786503`, closing issue #144 and
  validating Arrow Flight scan `FlightInfo` descriptor-ticket
  consistency. The local `FlightInfo` validator now decodes the command
  descriptor and endpoint ticket, compares the resulting scan requests,
  and rejects valid but mismatched descriptor/ticket pairs before
  treating scan info as valid. This remains local Arrow Flight scan
  `FlightInfo` fixture validation only; no Flight protocol expansion,
  distributed execution, SQL planner, predicate pushdown implementation,
  gateway direct reads, non-loopback exposure, production auth/IAM,
  background processing, or persistent per-tenant service process was
  added. Current coverage is 218 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `ffe2d7e`.
- `noetl/ehdb#147` merged on 2026-06-24 UTC as
  `f452decce58a191e33f2bbfcff893dd48e0544ea`, closing issue #146 and
  validating the local Arrow Flight scan `FlightInfo` endpoint envelope.
  The local `FlightInfo` validator now rejects endpoint locations,
  endpoint expiration timestamps, and endpoint app metadata so the
  single endpoint stays pre-network. This remains local Arrow Flight
  scan `FlightInfo` fixture validation only; no Flight protocol
  expansion, distributed execution, SQL planner, predicate pushdown
  implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 219 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `fafa8ac`.
- `noetl/ehdb#149` merged on 2026-06-24 UTC as
  `2812af14af09ddfb528cea8421586892f266f10a`, closing issue #148 and
  validating Arrow Flight scan `FlightInfo` schema metadata. The local
  `FlightInfo` validator now rejects missing or empty schema IPC bytes
  before treating scan info as valid. This remains local Arrow Flight
  scan `FlightInfo` fixture validation only; no Flight protocol
  expansion, distributed execution, SQL planner, predicate pushdown
  implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 220 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `d8887b3`.
- `noetl/ehdb#151` merged on 2026-06-24 UTC as
  `d17daa13d913e014fb4358ededc59c440fded2fd`, closing issue #150 and
  validating Arrow Flight scan `FlightInfo` schema IPC bytes. The local
  `FlightInfo` validator now decodes non-empty schema metadata as Arrow
  schema IPC bytes and rejects malformed schema payloads before treating
  scan info as valid. This remains local Arrow Flight scan `FlightInfo`
  fixture validation only; no Flight protocol expansion, distributed
  execution, SQL planner, predicate pushdown implementation, gateway
  direct reads, non-loopback exposure, production auth/IAM, background
  processing, or persistent per-tenant service process was added.
  Current coverage is 221 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `ed85824`.
- `noetl/ehdb#153` merged on 2026-06-24 UTC as
  `c188e3d49afe5f4be791b8ce8d92fd8b3cc2eb40`, closing issue #152 and
  validating Arrow Flight scan `FlightInfo` byte-count metadata. The
  local `FlightInfo` validator now requires positive `total_bytes`,
  rejecting zero byte-count fixtures while preserving negative
  byte-count rejection. This remains local Arrow Flight scan
  `FlightInfo` fixture validation only; no Flight protocol expansion,
  distributed execution, SQL planner, predicate pushdown implementation,
  gateway direct reads, non-loopback exposure, production auth/IAM,
  background processing, or persistent per-tenant service process was
  added. Current coverage is 222 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `259f20f`.
- `noetl/ehdb#155` merged on 2026-06-24 UTC as
  `e8589b86f5923dd9957c0b8494d5c6a8ce9e62f9`, closing issue #154 and
  validating Arrow Flight scan `FlightInfo` result consistency. EHDB now
  validates produced scan `FlightInfo` fixtures against the producing
  result schema, row count, encoded byte count, and expected scan ticket,
  rejecting internally consistent but wrong-ticket fixtures before they
  can be treated as produced metadata. This remains local Arrow Flight
  scan `FlightInfo` fixture validation only; no Flight protocol
  expansion, distributed execution, SQL planner, predicate pushdown
  implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 223 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `e4c3f91`.
- `noetl/ehdb#157` merged on 2026-06-24 UTC as
  `6f90a9f084ca23d502f93b0b025ecc026f21c474`, closing issue #156 and
  validating Arrow Flight scan `FlightInfo` against the expected scan
  ticket on the receiver side. `ScanFlightTicket` can now reject an
  internally consistent `FlightInfo` response that belongs to a
  different scan request, and the loopback client smoke path validates
  returned `FlightInfo` before using its endpoint ticket. This remains
  local Arrow Flight scan `FlightInfo` receiver-side validation only; no
  Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added. Current coverage is 224 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `babfe24`.
- `noetl/ehdb#159` merged on 2026-06-24 UTC as
  `4f154d99529e511bf64415461af7e59fed0b4c8d`, closing issue #158 and
  validating Arrow Flight scan `FlightInfo` schema-response consistency
  on the receiver side. `ScanFlightTicket` can now reject well-formed
  `FlightInfo` responses whose schema metadata differs from the schema
  returned by `get_schema`, and the loopback client smoke path validates
  that consistency before using the endpoint ticket. This remains local
  Arrow Flight scan `FlightInfo` receiver-side validation only; no Flight
  protocol expansion, distributed execution, SQL planner, predicate
  pushdown implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 225 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `1b978ce`.
- `noetl/ehdb#161` merged on 2026-06-25 UTC as
  `c599c181747031516eb10e596ec56441a3925cfc`, closing issue #160 and
  validating Arrow Flight scan data against returned `FlightInfo`
  metadata on the receiver side. `ArrowScanResult` can now validate
  returned `FlightData` streams against `FlightInfo` schema, row count,
  and encoded byte-count metadata; the loopback client smoke path also
  validates decoded scan output against returned `FlightInfo` before
  treating batches as coherent. This remains local Arrow Flight scan
  result receiver-side validation only; no Flight protocol expansion,
  distributed execution, SQL planner, predicate pushdown implementation,
  gateway direct reads, non-loopback exposure, production auth/IAM,
  background processing, or persistent per-tenant service process was
  added. Current coverage is 226 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `12adb4c`.
- `noetl/ehdb#163` merged on 2026-06-25 UTC as
  `188f0a82e17130792df3ad728cfa64b9fd6f1fcd`, closing issue #162 and
  adding validated Arrow Flight scan `FlightInfo` endpoint-ticket
  extraction on the receiver side. `ScanFlightTicket` now returns the
  endpoint ticket only after validating returned scan `FlightInfo`
  against the expected scan ticket; the loopback client smoke path uses
  that helper before `do_get`. This remains local Arrow Flight scan
  `FlightInfo` receiver-side validation only; no Flight protocol
  expansion, distributed execution, SQL planner, predicate pushdown
  implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 226 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `cf82e7a`.
- `noetl/ehdb#165` merged on 2026-06-25 UTC as
  `1fbd467802ccb8e902063364b83f712e53407679`, closing issue #164 and
  adding schema-aware Arrow Flight scan `FlightInfo` endpoint-ticket
  extraction on the receiver side. `ScanFlightTicket` now returns the
  endpoint ticket only after validating returned scan `FlightInfo`
  against both the expected scan ticket and expected Arrow schema; local
  service, server, and loopback client smoke paths use that helper
  before `do_get`. This remains local Arrow Flight scan `FlightInfo`
  receiver-side validation only; no Flight protocol expansion,
  distributed execution, SQL planner, predicate pushdown implementation,
  gateway direct reads, non-loopback exposure, production auth/IAM,
  background processing, or persistent per-tenant service process was
  added. Current coverage is 226 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `0a94d39`.
- `noetl/ehdb#167` merged on 2026-06-25 UTC as
  `25643a903c0d3ea7426d25e719b99d8c228e0de7`, closing issue #166 and
  adding receiver-side Arrow Flight scan data validation against the
  expected scan ticket. `ArrowScanResult` now has helpers for raw
  `FlightData` streams and decoded Arrow batches that validate returned
  data against returned `FlightInfo` plus the expected
  `ScanFlightTicket`; local service, server, and loopback client smoke
  paths use those helpers before treating returned scan data as
  coherent. This remains local Arrow Flight scan data receiver-side
  validation only; no Flight protocol expansion, distributed execution,
  SQL planner, predicate pushdown implementation, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  226 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `5f87b33`.
- `noetl/ehdb#169` merged on 2026-06-25 UTC as
  `0e4b518ac8b23433c4a312c24f3e533c1a1dff8a`, closing issue #168 and
  adding receiver-side Arrow Flight schema-result validation against
  returned scan `FlightInfo`. `ScanFlightTicket` now decodes returned
  `SchemaResult` values and validates returned `FlightInfo` against the
  expected scan ticket plus decoded schema; local service and server
  receiver paths use this before treating `get_schema` and
  `get_flight_info` as coherent, while loopback client paths validate
  already-decoded schemas against returned `FlightInfo`. This remains
  local Arrow Flight schema/scan-info receiver-side validation only; no
  Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added. Current coverage is 226 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `cee1652`.
- `noetl/ehdb#171` merged on 2026-06-25 UTC as
  `11f8e0f7441bf12b92cdf7bcff681752d59598ff`, closing issue #170 and
  adding receiver-side Arrow Flight schema-result endpoint-ticket
  extraction. `ScanFlightTicket` now decodes returned `SchemaResult`,
  validates returned `FlightInfo` against the expected scan ticket plus
  decoded schema, and returns the decoded schema plus validated endpoint
  ticket for `do_get`; local service and server receiver paths use this
  before `do_get`. This remains local Arrow Flight schema/scan-info
  endpoint-ticket receiver-side validation only; no Flight protocol
  expansion, distributed execution, SQL planner, predicate pushdown
  implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 226 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `e6ac75a`.
- `noetl/ehdb#173` merged on 2026-06-25 UTC as
  `03c272f8b87b7a9d97d462990885a5fe0e0f07da`, closing issue #172 and
  adding receiver-side Arrow Flight decoded client response validation.
  `ArrowScanResult` now validates decoded Arrow batches against the
  decoded `get_schema` schema, returned scan `FlightInfo`, and expected
  `ScanFlightTicket` together; loopback client smoke paths use this
  before treating returned batches as coherent. This remains local Arrow
  Flight decoded client response receiver-side validation only; no Flight
  protocol expansion, distributed execution, SQL planner, predicate
  pushdown implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 226 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `f367421`.
- `noetl/ehdb#175` merged on 2026-06-25 UTC as
  `42975587be9ef6cf10416d11b02232ed76aab321`, closing issue #174 and
  adding receiver-side Arrow Flight raw scan data schema validation.
  `ArrowScanResult` now validates raw `FlightData` streams against the
  decoded `get_schema` schema, returned scan `FlightInfo`, and expected
  `ScanFlightTicket` together; local service and server receiver paths
  use this before accepting decoded rows from `do_get`. This remains
  local Arrow Flight raw scan data receiver-side validation only; no
  Flight protocol expansion, distributed execution, SQL planner,
  predicate pushdown implementation, gateway direct reads, non-loopback
  exposure, production auth/IAM, background processing, or persistent
  per-tenant service process was added. Current coverage is 226 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `dcc707b`.
- `noetl/ehdb#177` merged on 2026-06-25 UTC as
  `c6a7ca8822ba7cc61296393505d0d2260742a2e0`, closing issue #176 and
  adding receiver-side Arrow Flight scan response envelope validation.
  `ArrowScanResult` now validates the complete local scan response
  envelope: raw `SchemaResult`, returned scan `FlightInfo`, raw
  `FlightData`, and expected `ScanFlightTicket`; local service and
  server receiver paths use this before accepting decoded rows from
  `do_get`. This remains local Arrow Flight scan response receiver-side
  validation only; no Flight protocol expansion, distributed execution,
  SQL planner, predicate pushdown implementation, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  226 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `ef3fbe5`.
- `noetl/ehdb#179` merged on 2026-06-25 UTC as
  `f1a7e197f3507deca4bc3e7084f4b65d1b980c0b`, closing issue #178 and
  adding receiver-side Arrow Flight `do_get` endpoint-ticket binding.
  `ScanFlightTicket` now validates the concrete endpoint `Ticket` used
  for `do_get` against returned scan `FlightInfo`, decoded schema, and
  the expected scan ticket; local service/server and loopback client
  receiver paths use this before accepting `do_get` results as coherent.
  This remains local Arrow Flight endpoint-ticket receiver-side
  validation only; no Flight protocol expansion, distributed execution,
  SQL planner, predicate pushdown implementation, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  226 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `a76d55a`.
- `noetl/ehdb#181` merged on 2026-06-25 UTC as
  `1bfbf73696ee1611de04ca774e9050825bee70d0`, closing issue #180 and
  adding local Arrow scan projection selector shape validation.
  `ScanFlightTicket` and `LocalArrowScanService` now reject empty
  projection lists and duplicate projection columns before scan
  execution or Flight ticket encode/decode succeeds, preserving valid
  projection/filter scans. This remains local scan request selector
  validation only; no Flight protocol expansion, distributed execution,
  SQL planner, predicate pushdown implementation, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  228 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `e272a99`.
- `noetl/ehdb#183` merged on 2026-06-25 UTC as
  `9a60c4da5bc961124dc21f16454047c8dbf1f3a1`, closing issue #182 and
  adding local Arrow Flight scan command descriptor path validation.
  `LocalArrowFlightServer` now rejects direct `get_flight_info` and
  `get_schema` command descriptors that carry non-empty path entries
  before scan execution, while valid descriptors produced by
  `ScanFlightTicket::command_descriptor` continue to work. This remains
  local Arrow Flight scan descriptor request validation only; no Flight
  protocol expansion, distributed execution, SQL planner, predicate
  pushdown implementation, gateway direct reads, non-loopback exposure,
  production auth/IAM, background processing, or persistent per-tenant
  service process was added. Current coverage is 229 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `69f1bee`.
- `noetl/ehdb#185` merged on 2026-06-25 UTC as
  `3c460370cc3724ea2e08cfaffbbcf523e63522e3`, closing issue #184 and
  adding strict local Arrow Flight scan ticket payload validation.
  `ScanFlightTicket::decode` now rejects unknown top-level ticket fields,
  unknown embedded latest-table scan request fields, and unknown
  equality predicate fields before scan execution or Flight handoff.
  This remains local Arrow Flight scan ticket/request payload validation
  only; no Flight protocol expansion, distributed execution, SQL
  planner, predicate pushdown implementation, gateway direct reads,
  non-loopback exposure, production auth/IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  230 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `4ba0753`.
- `noetl/ehdb#187` merged on 2026-06-25 UTC as
  `dd4633aeeb85270b593256141aa74b98f4ee4586`, closing issue #186 and
  adding canonical local Arrow Flight scan ticket byte validation.
  `ScanFlightTicket::decode` now rejects pretty-printed or otherwise
  non-canonical JSON bytes unless they exactly match the EHDB encoding
  produced by `ScanFlightTicket::encode`; `to_arrow_ticket`,
  `command_descriptor`, and implemented server scan methods remain on
  that stricter decode path. This remains local Arrow Flight scan ticket
  byte-contract validation only; no Flight protocol expansion,
  distributed execution, SQL planner, predicate pushdown implementation,
  gateway direct reads, non-loopback exposure, production auth/IAM,
  background processing, or persistent per-tenant service process was
  added. Current coverage is 231 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `df2f341`.
- `noetl/ehdb#189` merged on 2026-06-25 UTC as
  `9c80d974aefc7abe5582d0c8da0732ab1f88e004`, closing issue #188 and
  adding strict local retrieval context payload field validation.
  `RetrievalContextRequestPayload::decode` and
  `RetrievalContextResultPayload::decode` now reject unknown request
  envelope, assembly request, result envelope, context object, and
  context block fields before local worker/playbook execution or handoff.
  This remains local retrieval context worker/playbook payload
  validation only; no network API, gateway route, prompt engine, LLM
  invocation, retrieval daemon, distributed search service, production
  IAM, background processing, or persistent per-tenant service process
  was added. Current coverage is 233 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `a3ab141`.
- `noetl/ehdb#191` merged on 2026-06-25 UTC as
  `f28f1492cc2a30d76f00f81f61859bc3ebe2035a`, closing issue #190 and
  adding canonical local retrieval context payload byte validation.
  `RetrievalContextRequestPayload::decode` and
  `RetrievalContextResultPayload::decode` now reject pretty-printed or
  otherwise non-canonical JSON bytes unless they exactly match the EHDB
  encoding produced by each payload's `encode` method. This remains
  local retrieval context worker/playbook payload byte-contract
  validation only; no network API, gateway route, prompt engine, LLM
  invocation, retrieval daemon, distributed search service, production
  IAM, background processing, or persistent per-tenant service process
  was added. Current coverage is 234 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `0e8aead`.
- `noetl/ehdb#193` merged on 2026-06-25 UTC as
  `b532146585b13b8a721c23ccffb2e57692f75a2a`, closing issue #192 and
  adding strict local retrieval context execution receipt payload field
  validation. `RetrievalContextPayloadExecutionReceiptPayload::decode`
  now rejects unknown receipt envelope and redacted execution summary
  fields before artifact validation, receipt decode, or receipt-event
  helper use. This remains local retrieval context receipt payload
  validation only; no stream publication behavior, network API, gateway
  route, prompt engine, LLM invocation, retrieval daemon, distributed
  search service, production IAM, background processing, or persistent
  per-tenant service process was added. Current coverage is 235 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `bea5ec4`.
- `noetl/ehdb#195` merged on 2026-06-25 UTC as
  `7fb92e9f5b7fdb1383e484a95a42f8b2f53a783d`, closing issue #194 and
  adding canonical local retrieval context execution receipt payload
  byte validation. `RetrievalContextPayloadExecutionReceiptPayload::decode`
  now rejects pretty-printed or otherwise non-canonical JSON bytes unless
  they exactly match the EHDB encoding produced by `encode`, before
  artifact validation, receipt decode handoff, or receipt-event helper
  use. This remains local retrieval context receipt payload
  byte-contract validation only; no stream publication behavior, network
  API, gateway route, prompt engine, LLM invocation, retrieval daemon,
  distributed search service, production IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  236 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `b6b58e3`.
- `noetl/ehdb#197` merged on 2026-06-25 UTC as
  `00b7a488b6617c02ef5fc716d027f03f8a167d8f`, closing issue #196 and
  adding strict local retrieval context execution receipt event payload
  field validation.
  `RetrievalContextPayloadExecutionReceiptEventPayload::decode` now
  rejects unknown event envelope fields before replay decode, publisher
  helper use, or consumer handoff while keeping nested receipt bytes on
  the strict canonical receipt decoder. This remains local retrieval
  context receipt event payload validation only; no stream publication
  behavior changes, network API, gateway route, prompt engine, LLM
  invocation, retrieval daemon, distributed search service, production
  IAM, background processing, or persistent per-tenant service process
  was added. Current coverage is 237 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `6010d30`.
- `noetl/ehdb#199` merged on 2026-06-25 UTC as
  `095db5246ecb272ece7a1ee07a871672808513fb`, closing issue #198 and
  adding canonical local retrieval context execution receipt event
  payload byte validation.
  `RetrievalContextPayloadExecutionReceiptEventPayload::decode` now
  rejects pretty-printed or otherwise non-canonical JSON bytes unless
  they exactly match the EHDB encoding produced by `encode`, before
  replay decode, publisher helper use, or consumer handoff while keeping
  nested receipt bytes on the strict canonical receipt decoder. This
  remains local retrieval context receipt event payload byte-contract
  validation only; no stream publication behavior changes, network API,
  gateway route, prompt engine, LLM invocation, retrieval daemon,
  distributed search service, production IAM, background processing, or
  persistent per-tenant service process was added. Current coverage is
  238 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `c6c5a9c`.
- `noetl/ehdb#201` merged on 2026-06-25 UTC as
  `d14eba7589bae84eb9089c35e904fbcb30afd7a0`, closing issue #200 and
  adding stream sequence serde validation for local JSONL stream journal
  replay. `StreamSequence` deserialization now preserves the same
  nonzero invariant as `StreamSequence::new`, so persisted zero publish
  record sequences and zero ack cursor sequences are rejected before
  retained records or durable consumer cursors are rebuilt. This remains
  local stream journal replay validation only; no stream publication
  behavior changes, network API, gateway route, prompt engine, LLM
  invocation, retrieval daemon, distributed search service, production
  IAM, background processing, or persistent per-tenant service process
  was added. Current coverage is 241 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `6c0b603`.
- `noetl/ehdb#203` merged on 2026-06-25 UTC as
  `89e35cff7f90e36b02ec47ba521428b5629c4199`, closing issue #202 and
  adding strict JSONL stream journal field replay validation. Stream
  journal entries, stream configs, stream records, and durable consumer
  records now reject unknown persisted fields during replay instead of
  silently ignoring them before rebuilding stream state. This remains
  local stream journal replay validation only; no stream publication
  behavior changes, network API, gateway route, prompt engine, LLM
  invocation, retrieval daemon, distributed search service, production
  IAM, background processing, or persistent per-tenant service process
  was added. Current coverage is 242 Rust tests plus Criterion
  benchmark compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `317774a`.
- `noetl/ehdb#205` merged on 2026-06-25 UTC as
  `4fdd7f4d7e7641845767382501bee3fd3dbd6d75`, closing issue #204 and
  adding strict JSONL transaction journal field replay validation.
  Transaction records plus catalog, stream, retrieval, system-library,
  and storage mutation payloads now reject unknown persisted fields
  during replay instead of silently ignoring them before rebuilding
  ordered state. This remains local transaction journal replay
  validation only; no network API, gateway route, prompt engine, LLM
  invocation, retrieval daemon, distributed transaction coordinator,
  production replication, background processing, or persistent
  per-tenant service process was added. Current coverage is 243 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `3986c6a`.
- `noetl/ehdb#207` merged on 2026-06-25 UTC as
  `3fe220226f8a96bfc752654b192548b0578a13ba`, closing issue #206 and
  adding strict JSONL system-library journal field replay validation.
  Local system-library journal entries plus persisted publish and bind
  request payloads now reject unknown fields during replay before
  rebuilding WASM manifest and hot-replacement binding state. This
  remains local system-library journal replay validation only; no WASM
  execution, background processing, network API, gateway data-touch
  behavior, production replication, scheduler behavior, object transfer
  execution, distributed transaction coordinator, or persistent
  per-tenant service process was added. Current coverage is 244 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `774062f`.
- `noetl/ehdb#209` merged on 2026-06-25 UTC as
  `eb191349e46d60606d3311f84c4eb69b1b1d5520`, closing issue #208 and
  adding strict storage metadata JSON decode validation. Object refs,
  geo placements, placement policy targets, replica records,
  replication actions, replication plans, and the local replica registry
  now reject unknown JSON fields before replay or planning treats the
  metadata as valid routing state. This remains storage metadata decode
  validation only; no object movement, cloud adapters, network API,
  gateway data-touch behavior, production replication, scheduler,
  background worker, or persistent per-tenant service process was added.
  Current coverage is 245 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `947b19b`.
- `noetl/ehdb#211` merged on 2026-06-25 UTC as
  `390a94110cf0acdedd8a61def1eba5e982196dc3`, closing issue #210 and
  adding strict catalog metadata JSON decode validation. Catalog tables,
  snapshots, scan grants, create-table requests, snapshot commits, scan
  grant requests, table schemas, and column schemas now reject unknown
  JSON fields before persisted metadata is accepted for replay or
  catalog operations. This remains catalog metadata decode validation
  only; no network API, gateway route, production ACL/IAM engine, query
  planner, distributed transaction coordinator, background worker, or
  persistent per-tenant service process was added. Current coverage is
  246 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `95da92e`.
- `noetl/ehdb#213` merged on 2026-06-25 UTC as
  `9458476eeb7474ba807974e9facaeb7c769e274d`, closing issue #212 and
  adding strict retrieval metadata JSON decode validation. Retrieval
  documents, chunks, embeddings, registration requests, vector/text/
  hybrid search requests, and local search hit metadata now reject
  unknown JSON fields before persisted or handed-off RAG metadata is
  accepted. This remains retrieval metadata decode validation only; no
  ANN index, full-text index, retrieval daemon, network API, gateway
  route, prompt engine, LLM invocation, production IAM, query planner,
  background worker, or persistent per-tenant service process was added.
  Current coverage is 247 Rust tests plus Criterion benchmark
  compilation. `repos/ehdb` should point at this merged SHA;
  `repos/ehdb-wiki` should point at `abc6ef0`.
- `noetl/ehdb#215` merged on 2026-06-25 UTC as
  `a7776b919a82130ac5f249b88f367d886c258304`, closing issue #214 and
  adding strict system-library metadata JSON decode validation. Resolved
  WASM library manifests, NoETL plugin refs, and environment/channel
  binding metadata now reject unknown JSON fields before persisted or
  handed-off system-library metadata is accepted. This remains
  system-library metadata decode validation only; no WASM execution,
  background processing, network API, gateway data-touch behavior,
  production replication, scheduler behavior, distributed transaction
  coordinator, object transfer execution, or persistent per-tenant
  service process was added. Current coverage is 248 Rust tests plus
  Criterion benchmark compilation. `repos/ehdb` should point at this
  merged SHA; `repos/ehdb-wiki` should point at `3454b96`.
- `noetl/ehdb#217` merged on 2026-07-02 UTC as
  `f95aeae0ec3415ce72690383cbb3756e73aadf76`, closing issue #216 and
  adding direct local Arrow scan projection shape validation. The
  `LocalArrowSnapshotScanner` now rejects empty projection lists and
  duplicate projection columns before object reads, keeping the direct
  local scanner aligned with the service/Flight projection contract
  while preserving ordered valid projections and existing missing-column
  errors. This remains local Arrow IPC scan request validation only; no
  SQL planning, predicate pushdown, distributed execution, gateway
  direct reads, Arrow Flight protocol changes, production IAM/ACL
  behavior, request scheduling, object movement, or persistent
  per-tenant service process was added. Current coverage is 249 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `aa11507`.
- `noetl/ehdb#219` merged on 2026-07-02 UTC as
  `714a50b932cb09891f2eb9f97ef9496949c3ed3c`, closing issue #218 and
  adding direct local Arrow scan selector identifier validation. The
  `LocalArrowSnapshotScanner` now validates projection-column and
  equality-predicate column selector identifiers before object reads,
  while preserving `NotFound` behavior for valid-but-missing selector
  columns. This remains direct local Arrow IPC scan selector validation
  only; no SQL planning, predicate pushdown, distributed execution,
  gateway direct reads, Arrow Flight protocol changes, production
  IAM/ACL behavior, request scheduling, object movement, or persistent
  per-tenant service process was added. Current coverage is 250 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `d858fb2`.
- `noetl/ehdb#221` merged on 2026-07-02 UTC as
  `6cc5d8edeb7637304458657acafd7f85fc37785e`, closing issue #220 and
  adding duplicate table schema column validation. `TableSchema::new`
  now rejects duplicate column names before catalog state is created,
  preserving non-empty schema and per-column identifier validation while
  keeping Arrow projection and predicate selectors unambiguous. This
  remains table schema validation only; no schema evolution, type
  coercion, SQL planning, predicate pushdown, distributed execution,
  gateway direct reads, production IAM/ACL behavior, object movement, or
  persistent per-tenant service process was added. Current coverage is
  251 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `9cd4807`.
- `noetl/ehdb#223` merged on 2026-07-02 UTC as
  `20d4bca81dd32c91ebb7ed17425a29951e59850b`, closing issue #222 and
  adding table schema column identifier revalidation. `TableSchema::new`
  now revalidates every column identifier, including preconstructed or
  decoded `ColumnSchema` values, before catalog state is created. This
  preserves non-empty schema and duplicate-column validation while
  keeping Arrow projection and predicate selectors unambiguous. This
  remains table schema validation only; no schema evolution, type
  coercion, SQL planning, predicate pushdown, distributed execution,
  gateway direct reads, production IAM/ACL behavior, object movement, or
  persistent per-tenant service process was added. Current coverage is
  252 Rust tests plus Criterion benchmark compilation. `repos/ehdb`
  should point at this merged SHA; `repos/ehdb-wiki` should point at
  `04e06b4`.
- `noetl/ehdb#225` merged on 2026-07-02 UTC as
  `7c00dd7e185a02ecd4922de17ff0160a2018515c`, closing issue #224 and
  adding table/column schema JSON decode validation. `ColumnSchema`
  decode now routes through `ColumnSchema::new`, and `TableSchema`
  decode routes through `TableSchema::new`, preserving strict
  unknown-field behavior and the existing JSON shape while rejecting
  invalid column identifiers and duplicate table schema columns during
  metadata decode. This remains table/column schema JSON decode
  validation only; no schema evolution, type coercion, SQL planning,
  predicate pushdown, distributed execution, gateway direct reads,
  production IAM/ACL behavior, object movement, or persistent
  per-tenant service process was added. Current coverage is 253 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `a2cc35b`.
- `noetl/ehdb#227` merged on 2026-07-02 UTC as
  `6a875c70b0d25f038bef73a2ebdaa776a5e9c922`, closing issue #226 and
  adding core identifier JSON decode validation. Core identifier
  newtypes now deserialize JSON through their constructors, preserving
  the existing string JSON shape while rejecting malformed tenant,
  namespace, table, transaction, stream, retrieval, and related
  identifiers before metadata is accepted. Service payload decoders and
  JSONL replay boundaries keep malformed identifiers classified as
  `EhdbError::InvalidIdentifier` while preserving storage/state errors
  for corrupt or unknown-field payloads. This remains core identifier
  JSON decode validation only; no schema evolution, type coercion, SQL
  planning, predicate pushdown, distributed execution, gateway direct
  reads, production IAM/ACL behavior, object movement, or persistent
  per-tenant service process was added. Current coverage is 254 Rust
  tests plus Criterion benchmark compilation. `repos/ehdb` should point
  at this merged SHA; `repos/ehdb-wiki` should point at `698cf29`.
- `noetl/ehdb#229` merged on 2026-07-03 UTC as
  `200ade198095d172a796bce8d1bcd076f39ec9ba`, closing issue #228 and
  adding a NoETL runtime surface replay fixture. The new
  `ehdb-reference` integration test drives a worker/playbook-shaped
  flow only through `LocalReferenceRuntime` appends, then reopens the
  runtime and verifies catalog scan grants, stream consumer replay,
  retrieval text lookup, system WASM library resolution, and storage
  replica inventory from transaction replay. This remains a local
  reference/runtime integration fixture only; no gateway route, direct
  gateway data access, persistent per-tenant service, production IAM,
  distributed execution, SQL planning, object movement, or external
  dependency replacement behavior was added. Current coverage is 255
  Rust tests plus Criterion benchmark compilation. `repos/ehdb` should
  point at this merged SHA; `repos/ehdb-wiki` should point at
  `8cacacf`.
- `noetl/ehdb#231` merged on 2026-07-03 UTC as
  `16bba82eca54ade012fcfa2b9bf96149e7cb5102`, closing issue #230 and
  adding embedded NoETL role/capability policy in `ehdb-core`. EHDB can
  now model itself as an embedded distributed database substrate across
  NoETL workers, APIs, gateways, playbooks, and system contexts while
  preserving the execution-model boundary: gateway/API roles default to
  control-plane-only embedding, and worker/playbook/system roles carry
  explicit data-plane capabilities for bounded catalog, transaction,
  stream, object, retrieval, replication, and system-library work. This
  is policy/modeling only; it does not add a daemon, network API,
  gateway route, SQL planner, distributed executor, production IAM,
  storage mutation behavior, or persistent per-tenant process.
  Validation covered `cargo fmt`, `cargo fmt --all --check`,
  `cargo test -p ehdb-core`, `cargo test --workspace`, and
  `cargo bench --workspace --no-run`. Current coverage is 258 Rust tests
  plus Criterion benchmark compilation. `repos/ehdb` should point at
  this merged SHA; `repos/ehdb-wiki` should point at `0a0c010`.
- `noetl/noetl#669` merged on 2026-07-03 UTC as
  `4a8caeb7e587aa1d519ae6ee298b472c5c36594e`, closing issue #668 and
  adding the first NoETL-side EHDB integration contract. EHDB remains
  disabled by default in NoETL. `noetl.core.ehdb_contract` validates
  `NOETL_EHDB_ENABLED`, `NOETL_EHDB_MODE=local_reference`,
  `NOETL_EHDB_CLIENT_ROLE`, and `NOETL_EHDB_LOCAL_REFERENCE_LOG`.
  Worker/playbook local-reference roles are accepted with an explicit
  event-log path; gateway/server roles are rejected so gateway remains
  a gatekeeper and cannot touch EHDB data directly. This is a
  contract/readiness slice only; it does not connect to EHDB, replace
  PostgreSQL/NATS/object stores, add a gateway route, start a
  persistent per-tenant process, or perform a kind/GKE rollout.
  Validation covered 8 focused tests, 57 nearby runtime tests, and
  `compileall` for the new module. `repos/noetl` should point at this
  merged SHA.
- `noetl/noetl#671` merged on 2026-07-03 UTC as
  `d22edb5e8a997d8634dd6b40be02953c9ba92923`, closing issue #670 and
  adding the NoETL EHDB local-reference adapter descriptor.
  `noetl.core.ehdb_adapter.ehdb_adapter_from_env` returns `None` when
  EHDB is disabled and builds a `LocalReferenceEhdbAdapter` only for
  worker/playbook `local_reference` contracts with an explicit event-log
  path. The adapter can export runtime env for future helper calls but
  remains side-effect-free: it does not open logs, connect to EHDB,
  replace existing dependencies, add gateway/server data paths, or start
  persistent per-tenant processes. Validation covered the EHDB contract
  and adapter tests plus nearby runtime topology/pool-routing tests and
  `compileall` for the EHDB modules. `repos/noetl` should point at this
  merged SHA.
- `noetl/noetl#673` merged on 2026-07-03 UTC as
  `aa35becaecb53d00e44aff08b692d2468c75aa94`, closing issue #672 and
  adding the NoETL EHDB local-reference helper invocation plan.
  `noetl.core.ehdb_adapter.ehdb_helper_invocation_from_env` returns
  `None` when EHDB is disabled and, for enabled worker/playbook
  local-reference configs, requires an explicit `NOETL_EHDB_HELPER_BIN`
  before producing deterministic `argv` plus EHDB runtime env.
  `LocalReferenceEhdbInvocation` can merge that env into a subprocess
  environment, but remains an immutable plan only: it does not execute a
  subprocess, import Rust EHDB, open logs, connect to storage, replace
  dependencies, add gateway/server data paths, or start persistent
  per-tenant services. Validation covered 21 EHDB contract/adapter
  tests, 70 nearby runtime tests, `compileall`, and diff whitespace.
  `repos/noetl` should point at this merged SHA.
- `noetl/noetl#675` merged on 2026-07-03 UTC as
  `71a0a87fd3ffdca2e56e3dca14c0de078257f54d`, closing issue #674 and
  adding the NoETL-side EHDB embedded control-plane contract.
  `noetl.core.ehdb_contract` now accepts explicit
  `NOETL_EHDB_MODE=control_plane` for gateway/API/server roles with
  `NOETL_EHDB_CAPABILITIES=control_plane`, while continuing to reject
  data-plane local-reference or data capabilities for those roles.
  Worker/playbook/system local-reference configs retain explicit
  event-log requirements and data-plane capability modeling.
  `ehdb_adapter_from_env` and `ehdb_helper_invocation_from_env` return
  `None` for control-plane mode because there is no data-plane helper to
  run. This is contract/modeling only; it does not connect to EHDB,
  import Rust EHDB, open local logs, execute helpers, add gateway
  routes, add storage behavior, or start persistent per-tenant services.
  Validation covered 32 EHDB contract/adapter tests, 81 nearby runtime
  tests, `compileall`, diff whitespace, and GitHub `forbid-client-term`.
  `repos/noetl` should point at this merged SHA.
- `noetl/noetl#677` merged on 2026-07-03 UTC as
  `6254c44aff6982ca6b127dfa7610b5dc68283e1a`, closing issue #676 and
  adding the NoETL EHDB control-plane embedding descriptor.
  `noetl.core.ehdb_control_plane.ehdb_control_plane_from_env` returns
  `None` when EHDB is disabled or configured for local-reference
  data-plane mode, and returns `ControlPlaneEhdbEmbedding` for explicit
  gateway/API/server `control_plane` contracts. The descriptor carries
  role, `control_plane` capability, and exportable runtime env for
  planning-only embedding. This is descriptor/modeling only; it does not
  connect to EHDB, import Rust EHDB, open local logs, execute helpers,
  add gateway routes, add storage behavior, or start persistent
  per-tenant services. Validation covered 41 EHDB contract/adapter/
  control-plane tests, 90 nearby runtime tests, `compileall`, diff
  whitespace, and GitHub `forbid-client-term`. `repos/noetl` should
  point at this merged SHA.
- `noetl/noetl#679` merged on 2026-07-04 UTC as
  `a35316aa1e40d5a675213ffd7498c4870c1a212a`, closing issue #678 and
  adding the NoETL EHDB integration surface selector.
  `noetl.core.ehdb_surface.ehdb_surface_from_env` returns `None` when
  EHDB is disabled, selects `ControlPlaneEhdbEmbedding` for explicit
  gateway/API/server `control_plane` configs, and selects
  `LocalReferenceEhdbAdapter` for worker/playbook/system
  local-reference configs. The selected `EhdbIntegrationSurface`
  exposes role, mode, capabilities, and runtime env without opening
  logs, executing helpers, importing Rust EHDB, adding gateway routes,
  touching storage, or starting persistent per-tenant services.
  Validation covered 46 EHDB integration tests, 95 nearby runtime tests,
  `compileall`, diff whitespace, and GitHub `forbid-client-term`.
  `repos/noetl` should point at this merged SHA.
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
