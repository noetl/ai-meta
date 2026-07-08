# Agent Coordination

A shared "who's-working-on-what" board for the two AI agents that
develop this ecosystem — **Claude** and **Codex** — so they stay
deconflicted on shared surfaces (repos, branches, the prod server
image, the kind cluster, and ai-meta submodule pointers).

Wiki copy of this page:
[Agent-Coordination](https://github.com/noetl/ai-meta/wiki/Agent-Coordination).
The two copies drift together — edit both in the same change set.

## Purpose

Both agents work the same submodules from separate sessions with no
shared chat history. Without a durable board, they collide on shared
surfaces — two dirty submodule pointers swept into one commit, two
server images racing to prod, one agent deleting the other's kind
resources.

This page is the deconfliction surface. **Each agent appends a dated
line before and after a work session** so the other can see the
lane, the branches in flight, the review-gated PRs, and any
prod/kind action. Keep entries terse; the board is append-only —
never rewrite a prior line.

### Line format

```
YYYY-MM-DD · <agent> · <lane> · active: <what> · repos/branches: <list>
    · review-gated PRs: <#refs or none> · prod/kind: <action or none>
```

## Lanes (current ownership)

### CLAUDE → EHDB integration

- **Owns:** `repos/ehdb`, worker-rust EHDB integration
  (`repos/worker`), the EHDB Python-path disable (`repos/noetl`
  core), EHDB Helm env (`repos/ops`), the ehdb wiki
  (`repos/ehdb-wiki`).
- **Issues:** [noetl/ehdb#234](https://github.com/noetl/ehdb/issues/234)
  (umbrella) + [noetl/ehdb#238](https://github.com/noetl/ehdb/issues/238)
  (Rust-first re-home).
- **Shape:** EHDB is **disabled-by-default**; the engine is Rust;
  the Python EHDB path is being retired in favour of an in-process
  worker-rust integration (Rust-only). Python becomes a thin
  binding (Polars model).

### CODEX → travel workflows + JWT (#169) + SLM

- **Owns:** travel workflows (`repos/travel`: itinerary-planner,
  SPA, MCP agents); JWT / [#169](https://github.com/noetl/ai-meta/issues/169)
  auth (`repos/server` auth, `repos/gateway`, `repos/e2e`); SLM
  (`repos/ops` mlops).
- **Handover refs:**
  [`docs/CODEX-HANDOFF-PROMPT.md`](CODEX-HANDOFF-PROMPT.md),
  [`docs/HANDOVER-CODEX.md`](HANDOVER-CODEX.md),
  [`docs/HANDOVER-169-JWT.md`](HANDOVER-169-JWT.md),
  [`docs/CODEX-169-HANDOFF-PROMPT.md`](CODEX-169-HANDOFF-PROMPT.md).

## Shared surfaces / deconfliction rules

The important part. These are the surfaces both agents can touch —
each row says who owns it and how to avoid stepping on the other.

### `repos/noetl`

Both may touch. Codex: none currently. Claude: the EHDB Python
disable. **Rule:** serialize; announce the branch on this board
before pushing, so the other agent doesn't open a conflicting
branch on the same files.

### `repos/server`

Both. Codex owns auth / #169. Claude's EHDB control-plane guard
may add a **no-op / guard on the server ROLE only** (no data-plane
work). **Rule:** coordinate any server change; the EHDB side does
not touch auth. Announce before pushing a server branch.

### ai-meta pointer commits

Both agents bump submodule pointers. **Rule (primary deconfliction
mechanism):** every pointer-bump commit carries **only its own
intended gitlink(s)** — never sweep in the other agent's dirty
pointer. Use a no-checkout worktree + a scoped git index (or
`git commit -- <path>` targeting only the intended gitlink) so an
unrelated dirty `repos/*` pointer can't ride along. The superproject
working tree routinely shows many dirty pointers; a pointer-bump
commit must stage exactly the ones it means to record.

### prod server image

The server is currently **v3.52.0** (Codex's #169 JWT shadow +
#166 Phase 5, both flags OFF). **Rule:** announce on this board
before building or rolling a new server image. Both agents build
off `main`, so a fresh image includes both sides' merged code —
keep flags as intended and do not clobber the other's rollout
(e.g. don't flip `NOETL_AUTH_VERIFY_SIGNATURE` while shipping an
EHDB guard).

### kind cluster (`kind-noetl`)

Both may deploy. **Rule:** use distinct, labeled resource names
(`ehdb-*` vs `travel-*`), never delete the other's namespace or
resources, and **never touch GKE**. kind is the shared local
validation surface — treat the other agent's resources as
read-only.

### Review gates

`noetl/main` (and the submodule mains) are **REVIEW_REQUIRED**.
Neither agent admin-overrides a protected branch. When a merge is
blocked on review, surface it for the human on this board rather
than force-merging.

## Current status snapshot (2026-07-04)

### CLAUDE / EHDB

- Phases **A** ([ops#234](https://github.com/noetl/ops/pull/234)) /
  **B** ([noetl#688](https://github.com/noetl/noetl/pull/688)) /
  **C** ([ehdb#235](https://github.com/noetl/ehdb/pull/235) +
  [noetl#689](https://github.com/noetl/noetl/pull/689)) /
  **D** ([ehdb#237](https://github.com/noetl/ehdb/pull/237) +
  [noetl#690](https://github.com/noetl/noetl/pull/690)) **MERGED** —
  disabled-by-default, kind-validated and applied enabled in kind.
- **In progress:** Rust-only re-home into worker-rust + disable of
  the Python EHDB path (a build in flight; PRs to worker / noetl /
  ops incoming).
- **Open:** #234 (Phase E), #238 (re-home).

### CODEX / travel + JWT

- **planner v66 live** (guided-flow fix).
- **#169 JWT verification dark-launched** — server **v3.52.0** with
  `NOETL_AUTH_VERIFY_SIGNATURE=shadow` live, awaiting a real-login
  `success` metric, then the gated `enforce` flip (single-replica,
  instant rollback).
- **#166 Phase 5 merged** (flags OFF, rollout gated).
- **#177 Cloudflare native-Git** operator action open.

## Session board (append-only)

Newest last. Append a line before you start and after you finish.

```
2026-07-04 · Claude · EHDB · active: created this Agent-Coordination
    surface (wiki + docs mirror + issue cross-links); ehdb-wiki
    pointer bump to d0bb460 · repos/branches: ai-meta main (docs +
    pointer), repos/ai-meta-wiki master (this page) · review-gated
    PRs: none · prod/kind: none
2026-07-05 · Claude · EHDB · done: Phase 9 tier 1 (event log) —
    FIRST per-tier PRIMARY cutover activated + merged (LOCAL/kind
    scope only). ehdb#247 7f014c9 (exercise_primary_serve helper) +
    worker#161 ddf41de → v5.61.0 7e98538 (PRIMARY_SERVE_ACTIVATED
    false→true; NOETL_EHDB_EVENTLOG=primary serves the log
    authoritatively, dual-run + reversible). Touched repos/ehdb +
    repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane). ai-meta pointer bumps gitlink-only, one gitlink/commit:
    12ab324 (ehdb) / 38397f5 (ehdb-wiki) / 4c5e489 (worker). ·
    review-gated PRs: none (both merged) · kind dual-run: PENDING
    (env blocker — podman VM ssh gateway wedged; ~110-min image
    build) · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tier 2 (projection /
    read-model) — SECOND per-tier PRIMARY cutover activated + merged
    (LOCAL/kind scope only). ehdb#248 d08013c (projection
    exercise_primary_serve helper + ProjectionPrimaryServeReport) +
    worker#162 a56583c → v5.62.0 36875e3 (PRIMARY_SERVE_ACTIVATED
    false→true; NOETL_EHDB_PROJECTION=primary serves the read-models
    authoritatively, dual-run + reversible). Touched repos/ehdb +
    repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane). ai-meta pointer bumps gitlink-only, one gitlink/commit:
    79190f4 (ehdb) / a64f11a (worker) / 7cbfc19 (ehdb-wiki). ·
    review-gated PRs: none (both merged) · kind dual-run: BATCHED
    (env blocker — podman VM ssh gateway wedged; ~110-min image
    build) · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tiers 1 & 2 in-cluster
    kind dual-run VALIDATED (closes the tier-1 PENDING + tier-2
    BATCHED above). Recovered the wedged podman VM (machine
    stop/start reset the ssh socket), restarted kind cluster noetl,
    built worker v5.62.0 (36875e3, ships both tiers + ehdb-selfcheck)
    native-arm64, loaded into kind-noetl (sha256:9d222db6), ran
    ehdb-selfcheck eventlog-primary-serve + projection-primary-serve
    in a Job pod on node noetl-control-plane (ns ehdb-p9-validate):
    both tiers served_by_ehdb:true + reversible:true + dual_run_holds
    + secret-free metrics (exit 0), control-plane guard_refused
    (exit 4), pod Succeeded 0 restarts. NO new ehdb/worker code —
    validation only. repos/noetl + repos/server untouched (Codex
    lane); Codex's dirty repos/* pointers NOT swept. · ai-meta
    pointer bump gitlink-only, one gitlink: eea41bc (ehdb-wiki
    bc4470e→392348a). · review-gated PRs: none · kind dual-run:
    VALIDATED · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tier 3 (KV / state) —
    THIRD per-tier PRIMARY cutover activated + merged (LOCAL scope
    only). ehdb#249 73b1446 (kv exercise_primary_serve helper +
    KvPrimaryServeReport + kv-primary-serve CLI verb) + worker#163
    ba9f829 → v5.63.0 a7925e0 (PRIMARY_SERVE_ACTIVATED false→true;
    NOETL_EHDB_KV=primary serves the internal platform KV tier
    authoritatively vs the NATS-KV bucket, dual-run + reversible +
    serve_primary_cycle). Local ehdb-selfcheck kv-primary-serve:
    served_by_ehdb:true + reversible:true + dual_run_holds (5 served
    reads) + keys_after_revert:3 + secret-free metrics (exit 0),
    control-plane guard_refused (exit 4), off no-op (exit 0). Platform
    KV only (business KV stays external). Touched repos/ehdb +
    repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane); Codex's dirty repos/* pointers NOT swept. · ai-meta pointer
    bumps gitlink-only, one gitlink/commit: d8f85e0 (ehdb) / 105ab54
    (worker) / dff12fd (ehdb-wiki). · review-gated PRs: none (both
    merged) · kind dual-run: BATCHED (combined tier 3-5 run to follow)
    · prod/GKE cutover: STILL GATED on user, NOT performed
2026-07-05 · Claude · EHDB · done: Phase 9 tier 4 (object / blob) —
    FOURTH per-tier PRIMARY cutover activated + merged (LOCAL scope
    only). ehdb#250 bb42b8d (object exercise_primary_serve helper +
    ObjectPrimaryServeReport + object-primary-serve CLI verb) +
    worker#164 a100adf → v5.64.0 369e4c1 (PRIMARY_SERVE_ACTIVATED
    false→true; NOETL_EHDB_OBJECT=primary serves the internal platform
    object tier authoritatively vs the external object store — state
    shards #166 + result tier #104 — dual-run digest-parity +
    reversible + serve_primary_cycle). Local ehdb-selfcheck
    object-primary-serve: served_by_ehdb:true + reversible:true +
    dual_run_holds (4 served reads) + keys_after_revert:3 + secret-free
    metrics (exit 0), control-plane guard_refused (exit 4), off no-op
    (exit 0). Platform object tier only (business object buckets stay
    external). Touched repos/ehdb + repos/worker ONLY (repos/noetl +
    repos/server untouched — Codex lane); Codex's dirty repos/* pointers
    NOT swept. · ai-meta pointer bumps gitlink-only, one gitlink/commit:
    e195735 (ehdb) / 2dda3a7 (worker) / b97efe0 (ehdb-wiki). ·
    review-gated PRs: none (both merged) · kind dual-run: BATCHED
    (combined tier 3-5 run to follow) · prod/GKE cutover: STILL GATED
    on user, NOT performed
2026-07-06 · Claude · EHDB · done: Phase 9 tier 5 (vector) — FIFTH &
    FINAL per-tier PRIMARY cutover activated + merged (LOCAL scope
    only). ALL FIVE Phase-9 primary-serve activations now implemented.
    ehdb#251 0f47fe3 (vector exercise_primary_serve helper +
    VectorPrimaryServeReport + vector-primary-serve CLI verb) +
    worker#165 681782c → v5.65.0 ceedbba (PRIMARY_SERVE_ACTIVATED
    false→true; NOETL_EHDB_VECTOR=primary serves the internal platform
    vector tier — RAG / catalog embeddings — authoritatively vs the
    Qdrant retrieval path, dual-run top-k parity + reversible +
    serve_primary_cycle). Local ehdb-selfcheck vector-primary-serve:
    served_by_ehdb:true + reversible:true + dual_run_holds (3 served
    queries) + candidates_after_revert:3 + secret-free metrics (exit 0),
    control-plane guard_refused (exit 4), shadow primary_unavailable
    (exit 4), over-limit rejected (exit 3), off no-op (exit 0). Platform
    vectors only (business collections stay external). Touched repos/ehdb
    + repos/worker ONLY (repos/noetl + repos/server untouched — Codex
    lane); Codex's dirty repos/* pointers NOT swept. · ai-meta pointer
    bumps gitlink-only, one gitlink/commit: a5e96dd (ehdb) / 6daca1e
    (worker) / e35da39 (ehdb-wiki). · review-gated
    PRs: none (both merged) · kind dual-run: BATCHED (combined tier 3-5
    run to follow) · prod/GKE cutover: STILL GATED on user, NOT performed

2026-07-06 · Claude · EHDB · done: Phase 9 tiers 3-5 COMBINED in-kind
    dual-run VALIDATED → **Phase 9 CODE-COMPLETE**. Built worker v5.65.0
    image v5.65.0-p9 (7d30b250d261, native-arm64, ships ehdb-selfcheck),
    loaded into kind-noetl node containerd; Job ehdb-p9-t345 (ns
    ehdb-p9-validate) on node noetl-control-plane — container kernel
    6.19.7-200.fc43.aarch64 (Alpine 3.22), NOT macOS host; ctx kind-noetl
    API https://127.0.0.1:61866; pod Succeeded, 0 restarts. Tier 3 KV:
    served_primary + dual_run_holds (5 parities) + reversible
    (keys_after_revert:3) + guard_refused. Tier 4 object: served_primary +
    digest-integrity dual-run (4 parities) + reversible + guard_refused.
    Tier 5 vector: served_primary + top-k parity (ids/order/monotonic) +
    bounded cap (query_returned:3) + reversible + guard_refused. All
    secret-free; off=disabled no-op. Tiers 1-2 already validated 2026-07-05
    → all 5 tiers implemented + in-kind validated. Validation only, NO new
    code; repos/noetl + repos/server untouched (Codex lane); Codex's dirty
    repos/* pointers NOT swept. · ai-meta pointer bump gitlink-only, one
    gitlink/commit: dd516aa0 (ehdb-wiki→4597ae8). · review-gated PRs: none
    · kind dual-run: VALIDATED (all 5 tiers) · prod/GKE cutover: STILL
    GATED on user, NOT performed

2026-07-06 · Claude · EHDB · done: Phase 10 (Tunable-Backend Config
    Surface) IMPLEMENTED → **EHDB program (Phases 6-10) CODE-COMPLETE**.
    Consolidated the scattered NOETL_EHDB_* per-tier flags into one schema
    (ehdb-reference::backends: PlatformTier/TierMode/Backend/BackendMatrix,
    resolved enable→mode→backend, coherence validate() + secret-free render)
    + worker resolve(&EnvMap) reading each tier through its OWN from_env
    (backward-compat by construction) + ehdb-selfcheck `config` verb.
    Selfcheck matrix (batched in-kind, NO image build): all-external/all-ehdb/
    mixed coherent exit 0; primary-without-enable + control-plane-tier
    incoherent exit 4; secret_free, 0 leaks. Platform-only; EHDB default not
    lock-in; no behavior change (disabled-by-default no-op intact). repos/noetl
    + repos/server untouched (Codex lane); Codex's dirty repos/* pointers NOT
    swept. · repos/branches: ehdb#252 (merged 4c0df81), worker#166 (merged →
    v5.66.0 650fd68), ehdb-wiki b913cb0 · ai-meta gitlink-only, one gitlink/
    commit: repos/ehdb→4c0df81, repos/worker→650fd68, repos/ehdb-wiki→b913cb0
    · review-gated PRs: none · prod/GKE cutover: STILL GATED on user, NOT
    performed

2026-07-06 · Claude · EHDB · done: **EHDB Data Query Interface — read
    surface, first slice** (noetl/ai-meta#178). Codex PAUSED → worked
    repos/server + repos/cli directly (were previously Codex lane).
    Server `/api/ehdb/*` read-only API: executions list / execution state /
    event read-model (by-exec + global scan) served DIRECT from the
    read-model (ExecutionService); `tiers/{tier}` raw-tier ROUTING SEAM
    (501 + contract) — **no EHDB data-plane engine linked into the server**,
    control-plane guard held. Secret-free by construction (payload-free
    DTOs), bounded/paginated. CLI `noetl ehdb query executions|execution|
    events` (table + --json). New ehdb-wiki page. Read-only, platform-only,
    LOCAL/kind only — in-kind e2e PENDING image build. · repos/branches:
    server#277 (merged → v3.53.0 ec75812), cli#61 (merged 78c139b),
    ehdb-wiki 301688a · ai-meta gitlink-only, one gitlink/commit:
    repos/server→ec75812, repos/cli→<merge>, repos/ehdb-wiki→301688a ·
    review-gated PRs: none · prod/GKE: none (no prod, no GKE)

2026-07-06 · Claude · EHDB · done: **Durable event-log backend — first
    slice** (noetl/ehdb#254). Codex PAUSED → worked repos/ehdb directly.
    `ehdb-reference::durable_eventlog` — the production disk format the
    Phase-6 note deferred + the prod-cutover runbook §C durability gate
    names as the hard blocker for Stage C (local_reference is pod-local,
    lost on restart). DurableSegmentStore (append-only CRC32-framed
    seg-*.eslog + rollover + offset index + fsync + crash-recovery replay,
    torn-tail discard / bit-rot hard error, payload cold-load) +
    DurableEventLogDriver (same EventLogDriver contract) behind
    EventLogStorageBackend selector (local_reference default). CLI
    durable-eventlog-recovery proves zero-loss across a simulated restart.
    17 tests incl. parity vs LocalReference; clippy -D + fmt + workspace
    test green. LOCAL/code only — no GKE, no worker image build; in-kind
    PENDING. · repos/branches: ehdb#253 (merged → 99c4570), ehdb-wiki
    891d294 · ai-meta gitlink-only, one gitlink/commit: repos/ehdb→99c4570,
    repos/ehdb-wiki→891d294 · review-gated PRs: none · prod/GKE: none

2026-07-06 · Claude · EHDB · done: **program docs/hygiene consolidation**
    (docs-only — no code, no deploy, no prod/GKE; live kind stack server
    v3.53.0 + worker v5.67.0 shadow left running). Reconciled the whole EHDB
    program to one coherent current state: ehdb-wiki Roadmap + Home +
    Sessions-Log (Phase 6 shadow mirror now wired LIVE + proven on real
    in-kind drives 332760742153424896/…854506246144; Home Live-in-kind +
    What's-NOT-done-yet bullets); ai-meta MEMORY.md EHDB index compacted
    (all 26 topic-file pointers preserved). Posted state-of-program roll-up
    on ehdb#241; cross-linked ehdb#234 / ai-meta#178 / ehdb#254 (none
    closed — program continues). · repos/branches: ehdb-wiki 91e8823 (this
    consolidation) · ai-meta gitlink-only, one gitlink/commit:
    repos/ehdb-wiki→91e8823 (3656ae98; 7 other dirty repos/* pointers NOT
    swept) · review-gated PRs: none · prod/GKE: none

2026-07-07 · Claude · EHDB · done: **Durable event-log backend — slice 2
    (execution-affinity single-writer routing)** (noetl/ehdb#254 item 2).
    Worked repos/ehdb ONLY. `ehdb-reference::affinity` (ShardOwnership +
    shard_for_i64/shard_for_execution — XxHash64 seed-0 over the i64 exec id's
    LE bytes % shard_count, byte-identical to noetl-worker/server
    sharding::shard_for; twox-hash 1.6) + `durable_eventlog_affinity`
    (AffinityRoutedEventLog: per-shard DurableSegmentStore under
    <root>/shard-<NNNN>/; owner append serves, non-owner refused with no side
    effect route-to-owner, non-owner read cold-loads read-only via new
    DurableSegmentStore::open_read_only). CLI durable-eventlog-affinity{,-append,
    -read}; affinity-append exit 6 = refused-non-owner (distinct). Single-writer
    drive proves owner-writes/non-owner-refused/single-writer-invariant/
    cold-load-read/crash-recovery. 21 new tests; fmt+clippy -D+workspace test
    (200)+bench --no-run green. Disabled by default (single-owner; local_reference
    still default). LOCAL/code only — no GKE, no worker image build; in-kind
    PENDING (slice 5). **NOTE: a concurrent sibling task is wiring worker
    runtime-mirrors in repos/worker — this slice deliberately touched NO
    repos/worker files to avoid the collision; worker wiring is slice 4,
    deferred.** repos/noetl + repos/server untouched (Codex lane). ·
    repos/branches: ehdb#255 (merged → 6fbe88f), ehdb-wiki 4b5f122 · ai-meta
    gitlink-only, one gitlink/commit: repos/ehdb→6fbe88f + repos/ehdb-wiki→4b5f122
    (9ccc1f74; 8 other dirty repos/* pointers NOT swept incl. repos/worker) ·
    review-gated PRs: none · prod/GKE: none
2026-07-07 · Claude · EHDB · done: **KV + object tier shadow mirrors wired
    into the live worker runtime paths** (following the event-log tier, #167).
    Worked repos/worker ONLY (src/ehdb/{kv,object}.rs runtime_hook_env +
    mirror_live_put + their live invocation sites; src/ehdb/mod.rs status note).
    KV hooked at SpoolRuntime::persist_circuit (the NATS-KV circuit-state put,
    bucket noetl_subscription_circuit — the only live platform NATS-KV write);
    object hooked at ControlPlaneClient::object_put (the chokepoint every object
    tier — result-tier/state-shard/plugin — funnels through, digest parity;
    bytes cloned only when armed). projection + vector DEFERRED with documented
    seams (projection = shadow_project batch-materialize needs incumbent full
    fold → per-event hook would report false key-divergence; vector = no live
    platform vector-upsert site exists yet). Each hook env-armed (ENABLED +
    <TIER>=shadow + data-plane role), strict no-op otherwise, control-plane never
    mirrors, error-isolated (panic→Unavailable, metered, never propagated),
    secret-free metrics. 16 new hook tests + 158 ehdb tests green; clippy no new
    lints; ehdb-selfcheck builds. **NOTE: concurrent sibling durable-backend
    track also running (repos/ehdb segment store, ehdb#255 slice 2) — this round
    touched NO durable segment-store files.** repos/noetl + repos/server
    untouched (Codex lane). LOCAL/KIND only — NO GKE, NO image build inline;
    in-kind live-drive proof PENDING — redeploy (live pool on v5.67.0; v5.68.0
    carries hooks). · repos/branches: worker#168 (merged → 2ec2e2b, released
    v5.68.0 3927bdf), ehdb-wiki 69e4714 · ai-meta gitlink-only, one
    gitlink/commit: repos/worker→3927bdf (2117ef6) + repos/ehdb-wiki→69e4714
    (174194e4); other dirty repos/* pointers NOT swept · review-gated PRs: none ·
    prod/GKE: none
2026-07-07 · Claude · EHDB (durable-backend track) · done: durable
    event-log backend **slice 3 — shared/object-store segment tier**.
    ehdb#258 cca0d0d (`ehdb-reference::durable_eventlog_shared`):
    SharedSegmentBackend trait (FilesystemSharedBackend/PVC now, EHDB
    object tier later) + SharedTierEventLog (owner publishes segments to
    shared; non-owner cold-loads / new owner hydrates from shared);
    fixed-width digest-integrity-checked segment keys (avoids the
    object-tier subject-length trap). durable-eventlog-shared selfcheck
    holds (shard-count 2+4). 213 ehdb tests green, clippy -D clean, fmt
    clean. **TWO concurrent sibling tasks noted + respected: (1) object
    subject-length fix owns ehdb-reference/object.rs — merged as ehdb#256
    bbc5047, my slice-3 branched OFF main after it so cca0d0d has bbc5047
    as parent (no revert); (2) worker projection/vector runtime-mirror
    owns worker src/ehdb/{projection,vector}.rs — untouched. My branch
    touched ONLY durable_eventlog{,_shared}.rs + lib.rs + the CLI bin +
    is ehdb-crate-only (worker wiring is slice 4, left for the sibling/
    later).** repos/noetl + repos/server untouched. LOCAL/KIND only — NO
    GKE, NO worker image build (validated via cargo test + clippy +
    selfcheck). · repos/branches: ehdb#258 merged → cca0d0d,
    ehdb-wiki e5aa701 · ai-meta gitlink-only, one gitlink/commit:
    repos/ehdb→cca0d0d (53b9049) + repos/ehdb-wiki→e5aa701 (96ea714);
    other dirty repos/* pointers NOT swept · review-gated PRs: none ·
    prod/GKE: none
2026-07-07 · Claude · EHDB · done: projection + vector runtime mirrors
    (the last two tiers). PROJECTION live-wired via a windowed cadence
    hook at the off-server state-builder drain post-batch checkpoint
    (state_builder::run_drain_loop → projection::mirror_live_window) —
    NOT per-event (batch fold would report false key-divergence); fresh
    throwaway per-window store + independent worker-side fold, no false
    divergence. VECTOR mirror code-ready + tested but deliberately NOT
    live-wired — no platform vector-upsert site exists in the worker loop
    (RAG ingest is lexical); documented-unreachable, seam noted for a
    future executor embed+upsert. worker#170 → fa64e0a → v5.69.0 96a8b6b.
    **TWO concurrent sibling tasks noted + respected: (1) object
    subject-length fix owns ehdb-reference/object.rs + worker Cargo ehdb
    pin — already merged (ehdb#256 bbc5047 → worker v5.68.1); I branched
    OFF origin/main AFTER it, so my worker PR carries the bbc5047 pin, no
    revert. (2) durable segment-store owns ehdb durable files — untouched.
    I touched ONLY worker src/ehdb/{projection,vector,mod}.rs +
    state_builder.rs; object.rs + durable files NOT touched.** repos/noetl
    + repos/server untouched. LOCAL/KIND only — NO GKE, NO worker image
    build inline (validated via cargo test + clippy -D + selfcheck); prod
    stays worker v5.52.0, all NOETL_EHDB_* default off. In-kind live-drive
    re-proof PENDING redeploy. · repos/branches: worker#170 merged →
    fa64e0a (v5.69.0 96a8b6b), ehdb-wiki 4e5ec66 · ai-meta gitlink-only,
    one gitlink/commit: repos/worker→96a8b6b (a3c34cb) +
    repos/ehdb-wiki→4e5ec66 (d34ed5c); other dirty repos/* pointers NOT
    swept · review-gated PRs: none · prod/GKE: none
2026-07-07 · Claude · EHDB (durable-backend track) · done: durable
    event-log backend **slice 4 — WORKER WIRING** (ehdb#254 item 4).
    Worked repos/worker ONLY. New src/ehdb/eventlog_backend.rs selects the
    event-log storage engine from NOETL_EHDB_EVENTLOG_BACKEND
    (local_reference default | durable_segment); durable_segment builds the
    slice-1+2+3 stack (SharedTierEventLog over AffinityRoutedEventLog over
    per-shard DurableEventLogDriver) with ownership from the worker's OWN
    NOETL_SHARD_INDEX/COUNT (byte-identical XxHash64 to sharding::shard_for).
    mirror_event dispatches through it (shadow mirror + gated primary append);
    new EventLogOutcome::RoutedAway for non-owned single-writer refusals.
    Config matrix surfaces eventlog_storage_backend; new ehdb-selfcheck
    durable-eventlog verb proves durable-segment replay (reopen shard store
    read-only). ehdb-reference pin bbc5047→cca0d0d (slices 1-3 + object fix).
    13 new tests + 191 ehdb tests green; no new clippy warnings; fmt (reflow
    gotcha — reverted 30 unrelated cargo-fmt files). Disabled-by-default,
    reversible, byte-identical when unset. **SIBLING (concurrent): a v5.69.0
    kind redeploy/re-proof task is running (ops-only, builds the EXISTING
    image, NO worker code change) — minimal collision; worker moves to
    v5.70.0 independently. repos/ehdb UNCHANGED (already cca0d0d); repos/noetl
    + repos/server untouched.** LOCAL/KIND only — NO GKE, NO worker image
    build inline; in-cluster durable-backend live proof PENDING a redeploy
    (drive with NOETL_EHDB_EVENTLOG_BACKEND=durable_segment). · repos/branches:
    worker#171 merged → 9947d9b → release 5e71319 (v5.70.0), ehdb-wiki 3574456 ·
    ai-meta gitlink-only, one gitlink/commit via temp-index off HEAD:
    repos/worker→5e71319 (f5af0c3) + repos/ehdb-wiki→3574456 (ff21f283); other
    dirty repos/* pointers NOT swept, no sibling revert · #254 items 2/3/4
    checked off; #234/#254 open (slices 5 kind-soak + 6 prod sign-off) ·
    review-gated PRs: none · prod/GKE: none

2026-07-08 · Claude · EHDB · done: hardened KV + vector registry subjects
    against the 256-char NATS Subject cap — fixed-width SHA-256 digest token
    (noetl.kv.<bucket>.<sha256hex(key)>, noetl.vec.<sha256hex(col)>.<sha256hex(pt)>)
    instead of hex-of-full-id, mirroring the object fix #256; latent-only (live KV
    uses short circuit.<id> keys, no live vector site) so forward-safety, in-kind
    re-proof deferred. 220 crate tests + kv/vector primary-serve selfcheck green,
    clippy/fmt clean, no image build. · repos/branches: ehdb#259 merged → 52120a7,
    ehdb#260 opened+closed, worker#172 merged → 93363d4 → release 0fb7ea5
    (v5.70.1; pin cca0d0d→52120a7, pin+lockfile only), ehdb-wiki 2c7165c · ai-meta
    gitlink-only, one gitlink/commit via temp-index off HEAD: repos/ehdb→52120a7 +
    repos/worker→0fb7ea5 + repos/ehdb-wiki→2c7165c; other dirty repos/* pointers NOT
    swept, no sibling revert · only touched repos/ehdb (crates/ehdb-reference) +
    repos/worker (pin) +
    repos/ehdb-wiki; repos/noetl + repos/server untouched (Codex lane) ·
    review-gated PRs: none · prod/GKE: none

2026-07-07 · Claude · EHDB · done: durable event-log backend slice 5
    (kind soak) — built worker v5.70.0, rolled onto noetl-worker-rust with
    NOETL_EHDB_EVENTLOG_BACKEND=durable_segment on a 2Gi PVC; thousands of real
    drives accumulated CRC-framed segments, segment ROTATION fired in-cluster
    (seg-0001 sealed 8 387 133 B → seg-0002), mirror metrics past 11 731 with
    zero invalid/degraded, CRASH RECOVERY on a real pod delete+reschedule proved
    sealed-segment byte-identical + read-only replay of 11 856 records + gapless
    continuing sequence. LOCAL kind only. · repos/branches: no worker code change
    (validated already-merged v5.70.0 durable wiring; backend byte-identical to
    the current v5.70.1 pointer — #172 diff is KV/vector-only), ehdb-wiki
    8b20f73, ehdb#254 slice-5 checked · ai-meta gitlink-only: repos/ehdb-wiki→
    8b20f73 (+ ai-meta-wiki); NO sibling repos/* pointers swept · SHARED-TREE
    NOTE: the concurrent Codex worker#172 session fast-forwarded the shared
    repos/worker tree 5e71319→0fb7ea5 mid-build; image was built from the tree at
    build time (v5.70.0) so it was unaffected · only touched repos/ehdb-wiki +
    docs + memory; repos/noetl + repos/server untouched · review-gated PRs: none ·
    prod/GKE: none

2026-07-07 · Claude · EHDB (durable-backend track) · done: durable event-log
    backend slice 6 — prod-durability SIGN-OFF PACKAGE (DOCS/PLANNING ONLY, no
    prod action). New ehdb-wiki page Runbook-Durable-EventLog-Prod-Signoff:
    go/no-go checklist (D1-D11: D1/D2/D6/D8/D10 MET, D3/D4/D5/D7/D9
    NEEDS-PROD-VERIFICATION, D11=GAP no segment GC), evidence bundle (slices
    1-5), residual-risk register (R1 segment-GC=Stage-C blocker, R2 GKE storage
    class, R3 multi-replica affinity on the real event-writer pool, R4-R7),
    extended durable-shadow→durable-primary rollout sequence (A′ v5.70.1
    flags-off → B′ prod durable-shadow on a PVC → C′ primary, separately gated).
    VERDICT: GO to prod durable-SHADOW; Stage C gated on soak + GC decision.
    Cross-linked from tier-1 runbook §C + design page + _Sidebar; ehdb#254
    slice-6 package comment posted, box LEFT UNCHECKED. · ehdb-wiki f009220,
    ehdb#254 comment 4911623178 · ai-meta gitlink-only: repos/ehdb-wiki→f009220
    (+ ai-meta-wiki); NO sibling repos/* pointers swept · repos/noetl +
    repos/server untouched · review-gated PRs: none · prod/GKE: none

2026-07-07 · Claude · Kind-first validation · done: **full-functionality
    validation Phase 1 — inventory + baseline + first-run matrix** (Alesha
    directive: green ALL playbooks in LOCAL kind before GKE). Inventoried 268
    playbook/automation files (e2e+noetl+ops+travel). Standardised the kind
    baseline: all 4 worker pools → v5.70.0 (was skewed v5.70.0 user/v5.69.0
    others), server v3.53.0, EHDB tiers shadow, durable_segment non-primary on
    the user-pool PVC. Reset cleared a system-pool orchestrate backlog (~720
    stale `__orchestrate__` re-drives @ ~0.6/s) + leaked NATS consumers
    (`drifttest` 23 992 msgs + 8 orphaned `noetl_events` consumers) that were
    starving executions; post-reset `hello_world` = 4 s. Postgres `noetl.event`
    untouched. Runs: core self-contained **61 PASS/4 FAIL (65)**, extended
    in-cluster-infra **9 PASS/11 non-green (20)**, EHDB probes 2/2; EHDB
    projection/query/durable live, KV/object/vector shadow (segments
    26.9→32.3 MB). **2 platform bugs found: BUG-1 pagination
    max_iterations/retry continuation wedge; BUG-2 large-result
    output_select/storage-tier `/api/result/resolve` 404 (3 fixtures).** Rest
    non-green = cred setup (kafka/pubsub decryption, 2 missing aliases) + 6
    fixture DSL-drift. · ehdb-wiki 4a288de (new page
    Kind-Full-Functionality-Validation + _Sidebar + Sessions-Log) · ai-meta
    gitlink-only: repos/ehdb-wiki→4a288de; NO sibling repos/* pointers swept ·
    repos/noetl + repos/server untouched; NO code changes · review-gated PRs:
    none · prod/GKE: none
2026-07-08 · Claude · Kind-first validation · done: **two platform bugs FIXED**
    (umbrella ai-meta#179). BUG-1 pagination self-loop wedge (server#278
    orchestrate-core → v3.53.1): a step whose own next arc re-enters itself
    (src==target) was never a recognized loop back-edge — the #85 strict recency
    test (src.completed_at > target.completed_at) is impossible for one step
    (s>s=false); step wedged Completed, exit arc stayed Pending (14-event stall).
    Fix: treat src==target as a back-edge directly. BUG-2 large-result artifact-get
    resolve 404 (server#278 + worker#173 → v3.53.1 / v5.70.2): under #104
    dual-write retirement the worker exposed the legacy _ref while resolve read
    only result_store; fix = worker exposes canonical _ref under mint_authoritative
    + server resolves Canonical refs from the JSON object tier + object-store PUT
    body limit 2MB→64MB (producer-stage silently 413'd a 15MB result). Frozen OQ5
    dual-write untouched. All 5 fixtures COMPLETED in kind (eids in topic file).
    · shared surface: repos/server + repos/worker (Rust) — Claude authored both
    PRs directly per handoff-routing rule · ai-meta gitlink-only: repos/server→
    f4a3616 (v3.53.1) + repos/worker→7747d0b (v5.70.2); NO sibling repos/* swept ·
    kind LOCAL only, NO GKE/prod · review-gated PRs: self-merged #278/#173 (no CI
    gate configured)

2026-07-08 · Claude · Kind-first validation · done: **Phase 2 — GSM external
    integration GREEN + Muno end-to-end LIVE in kind.** New capability (Alesha):
    kind CAN reach Google Secret Manager. Stood up a deploy-time GSM metadata
    bridge — host-ADC token shim (:48710) → in-cluster socat relay
    (Deployment/Service gcp-metadata, ns noetl) → hostAliases
    metadata.google.internal on all 4 worker pools; plus
    NOETL_GCP_METADATA_TOKEN_URL + GOOGLE_CLOUD_PROJECT env on noetl-server.
    Unblocks BOTH GSM paths (server keychain provider:gcp + worker in-python
    metadata read). 9 providers LIVE: Duffel(10 offers)/GooglePlaces(10)/
    HotelBeds hotels+activities+transfers/Firestore/Snowflake/OpenAI/Anthropic.
    Muno planner (muno/playbooks/itinerary-planner v15 + 6 MCP sub-playbooks)
    full flow GREEN: flight→book(real Duffel TEST order)→hotels→activities→
    transfers→summary→map, all live. Kafka+PubSub subscription drains PASS.
    Residual: #151 keychain-template gap (amadeus/ops-LLM/auth0 complete but
    401 — cred reachable, fixture uses broken {{keychain}}), IBKR needs live
    gateway, 6 FIXTURE-E + 2 fixture-data. · shared surface: kind cluster
    (deploy-time env + gcp-metadata bridge Deployment/Service + worker
    hostAliases — NOT persisted to repos/ops manifests; session artifact) ·
    NO repos/noetl or repos/server source change · ai-meta gitlink-only:
    repos/ehdb-wiki (matrix + Sessions-Log) · kind LOCAL only, NO GKE/prod ·
    no secret values printed · review-gated PRs: none

2026-07-08 · Claude · Kind-first validation · done: **Phase 3 — #151
    keychain-template gap FIXED (platform) + durable GSM bridge.** Root cause:
    the drive (orchestrate-core::build_tool_command, in the system/orchestrate
    wasm plug-in) renders tool configs against a context with no `keychain`
    namespace → `{{ keychain.* }}` empty → 401. Fix DEFERS `keychain.*` through
    the drive (render_value_deferring_keychain) + resolves TRANSIENTLY at
    user-worker dispatch (secret never in noetl.event) + server resolves
    `kind: credential` entries. PRs **server#279 / worker#174 / e2e#85
    (fixtures) / ops#235 (durable bridge)**. Kind images server:v3.54.0-rc4 /
    worker:v5.71.0-rc3 (4 pools uniform). PROVEN: openai GET /v1/models 200
    (deferred, no leak); kind:credential probe deferred+resolved; amadeus token
    +search 200. NOT green = external account limits (OpenAI chat 429
    insufficient_quota billing; auth0 needs user creds) — like IBKR. Durable
    bridge: fixed-clusterIP 10.96.0.53 relay + hostAliases + launchd shim;
    pod-restart proof PASSED. KNOWN FOLLOW-UP: heavily-rerun execution_ai_analyze
    openai_triage resolves the key drive-side (event-log exposure) while fresh
    probes defer — not root-caused; audit render_pipeline_config. · shared
    surface: kind cluster (new images + durable bridge manifests now committed
    to repos/ops) · ai-meta gitlink-only: repos/ehdb-wiki (matrix + Sessions-Log)
    · **PRs OPEN, NOT merged** (leak-flag surfaced for review) — no ai-meta
    pointer bump · kind LOCAL only, NO GKE/prod · no secret values printed ·
    review-gated PRs: server#279, worker#174, e2e#85, ops#235

2026-07-08 · Claude · Kind-first validation · done: **Phase 3.5 — #151 PRs
    MERGED, event-log leak FIXED before merge, Auth0 GREEN, OpenAI+IBKR scoped
    out.** Re-verification caught a REAL leak the Phase-3 "known follow-up"
    hand-waved: a fresh two-step probe (http step referencing a prior step's
    output + a `{{ keychain.* }}` header — the openai_triage shape) leaked
    `Bearer sk-<key>` into command.issued on rc3. Root cause = hop position,
    not rerun count: the off-server drive runs as `__orchestrate__`
    (tool_kind=wasm) whose input embeds follow-up steps' `{{ keychain.* }}`;
    the worker's generic dispatch ran inject_keychain_namespace over that
    input → resolved the secret INTO the drive context → drive persisted it
    into the follow-up command.issued. Fix (worker#174): skip keychain
    inject/render for the `__orchestrate__` drive command; keychain resolves
    only at terminal user-pool dispatch. Rebuilt worker:v5.71.0-rc4, rolled 4
    pools. Before/after: `Bearer sk-<LEAKED>` → `Bearer {{ keychain.* }}` (0
    `Bearer sk-`); dispatch resolution intact; regression test added. MERGED
    (squash): server#279→v3.53.2 (fe500df9), worker#174→v5.70.3 (2031a8b4),
    e2e#85 (252006f8), ops#235 (541e6b0d). Auth0 password-grant GREEN via GSM
    (`auth0-test-user-password` → provider:gcp keychain, never plaintext
    workload): HTTP 200 + real access_token (expires_in 86400), COMPLETED, no
    plaintext in noetl.event, eid 333298747507216384. OpenAI (429
    insufficient_quota) + IBKR (live gateway) formally SCOPED OUT. · shared
    surface: kind cluster (4 worker pools on v5.71.0-rc4 = merged v5.70.3) ·
    ai-meta gitlink-only via temp-index off HEAD: server fe500df9, worker
    2031a8b4, e2e 252006f8, ops 541e6b0d, ehdb-wiki 96e31c0 · kind LOCAL only,
    NO GKE/prod · no secret values printed/committed
    · review-gated PRs: none (all merged)

2026-07-08 · Claude · EHDB integration · done: **EHDB perf/load-testing
    Phase 1 — engine micro-benchmarks + design doc.** New workstream
    ehdb#261 (on project 4). Deterministic criterion benches over all 5
    reference drivers + the durable segment event-log backend
    (`crates/ehdb-reference/benches/engine_micro.rs`, `cargo bench -p
    ehdb-reference --bench engine_micro`); seeded, isolated, no engine
    semantics changed. Baseline on M1 Max dev box (bench-only, NO deploy):
    durable event-log beats local_reference **2.7× at sustained append**
    (255 vs 96 ev/s @K=1000), flat ~3.9 ms/append (fsync-bound), rotation
    ~2%, cold replay ~185K ev/s; KV/object/vector reference drivers are
    O(n)/op shadow-only (no durable backend yet). SLO strawman drafted for
    Alesha to confirm; Layer B in-cluster load + EHDB-vs-incumbent
    (Postgres+JetStream) head-to-head = next phase pending scoping. ·
    shared surface: `repos/ehdb` (PR branch), `repos/ehdb-wiki`. · ai-meta
    gitlink-only via temp-index off HEAD: repos/ehdb + repos/ehdb-wiki
    (f887686). · **repos/noetl + repos/server UNTOUCHED (Codex lane).** ·
    kind: none touched · NO GKE/prod · no secret values ·
    review-gated PRs: **ehdb#262 OPEN** (bench-only; merge → pointer bump)
```

## Related

- [Handoffs](https://github.com/noetl/ai-meta/wiki/Handoffs) —
  file-based cross-agent dispatch (the heavier, structured
  coordination channel; this board is the lightweight always-on
  view). Rule: [`agents/rules/handoffs.md`](../agents/rules/handoffs.md).
- [Issue tracking](https://github.com/noetl/ai-meta/wiki/Issue-Tracking)
  — the durable task store; this board points into it, doesn't
  replace it. Rule: [`agents/rules/issue-tracking.md`](../agents/rules/issue-tracking.md).
- [Home](https://github.com/noetl/ai-meta/wiki/Home) — the
  ecosystem dashboard.
