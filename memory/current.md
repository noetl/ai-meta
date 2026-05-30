# Current Memory

Snapshot of the working state as of **2026-05-15**. Older detail has
been compacted into `memory/compactions/` and archived under
`memory/archive/`. Read the latest compaction
(`memory/compactions/20260515-173703.md`) if you need the full
inbox titles.

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
- Local NoETL CLI baseline: `noetl 2.14.x` at
  `/Volumes/X10/dev/cargo/bin/noetl`. Use for all ops/deploy/test
  automation.
- GCP project `noetl-demo-19700101` is operated under the **Adiona.org**
  organization context.
- Logging hygiene: suppress access logs or use DEBUG for
  high-frequency health/poll endpoints; any change that may increase
  request log volume needs a flood check.

### Runtime self-healing landed (2026-05-14 → 2026-05-15)

- **In-process command reaper** (`repos/noetl`) reinstated in
  `noetl/server/command_reaper.py`. Scans `noetl.command` for
  non-terminal commands whose execution is still live and
  republishes the original NATS notification under a `RuntimeLease`
  (`task_name="command_reaper"`). The existing `/api/commands/.../claim`
  endpoint and `noetl.claim_policy.decide_reclaim_for_existing_claim`
  stay the authority for reclaim correctness; the reaper never
  duplicates claim policy or forces completion. Env knobs:
  `NOETL_COMMAND_REAPER_{ENABLED,INTERVAL_SECONDS,WORKER_STALE_SECONDS,
  HEALTHY_HARD_TIMEOUT_SECONDS,PENDING_RETRY_SECONDS,MAX_PER_RUN}`.
- **Out-of-process runtime reaper surface** (`repos/doctor`) shipped
  as a Rust crate `noetl-doctor`: thin wrapper over the `noetl` Rust
  CLI that shells out to `noetl run --runtime local --set k=v ...`
  against bundled YAML playbooks under `playbooks/`. Playbooks follow
  the canonical `repos/ops` shape (`workload.action` dispatch with
  `help` default, `kind: shell` + psql/curl/jq, `ensure_kube_context`
  guard). Five bundled playbooks: `detect_stuck_executions`,
  `inspect_stale_commands`, `reachability_smoke`,
  `trigger_command_reaper`, `provision_doctor_mcp`. CLI exposes
  `detect / reachability / repair {trigger-reaper, run-playbook} /
  provision <verb> / mcp serve / playbooks`. The MCP HTTP surface
  mirrors the CLI 1:1 over `POST /tools/<name>/invoke`.
- **PFT v2 validation GREEN** (2026-05-15): execution
  `627209422065893596` for
  `fixtures/playbooks/pft_flow_test/test_pft_flow_v2` completed in
  `3h 54m 21s`. 10/10 facilities validated; each at `1000/1000` for
  assessments / conditions / medications / vital signs / demographics
  with non-zero MDS complete (facility 10 `22521/22521`). Final
  command table: 26199 COMPLETED, zero non-terminal. Server log shows
  the in-process reaper auto-recovered **two batches of 20 orphaned
  `fetch_mds_details:task_sequence` commands**
  (`[COMMAND-REAPER] Re-published 20/20 recovered commands` twice).
  Doctor was not on the critical path; doctor is the surface a
  monitoring system can call to detect or nudge the same recovery
  path, not the thing that actually fixes commands.

### GKE runtime reaper + PFT v2 validation amber (2026-05-15)

- GKE deploy completed to
  `gke_noetl-demo-19700101_us-central1_noetl-cluster` with:
  NoETL `pft-reaper-20260515-181717`, PFT test server
  `pft-reaper-20260515-181717`, runtime reaper doctor
  `pft-reaper-detect-healthy-20260515-190740`.
- GKE PFT v2 execution `627490002867323540` was later cancelled during
  tutorial validation because it was saturating the NoETL API/database
  pool. Before cancellation, facility 1 had completed and validated all
  domains including MDS (`22630/22630`), and the playbook had advanced
  into facility 2.
- Runtime reaper doctor fixes were made locally in `repos/doctor`:
  `provision_doctor_mcp.yaml` now patches optional DSN env separately
  instead of splicing fragile YAML; `detect_stuck_executions.yaml` no
  longer flags long-running `CLAIMED/RUNNING` commands when their worker
  is healthy and heartbeating. Local `cargo test` and `cargo clippy -D
  warnings` were green before rebuilding `noetl-doctor`.
- GKE observations to preserve:
  NATS briefly rescheduled during facility-1 MDS
  (`ConnectionRefusedError ... 34.118.228.11:4222`, pod event
  `Multi-Attach error` then recovery); NoETL API status intermittently
  hit DB pool pressure (`the pool 'noetl_server' has already 50 requests
  waiting`, `couldn't get a connection after 30.00 sec`). Direct
  in-cluster SQL probes were more reliable during the heavy MDS phase.
- Detailed handoff note:
  `memory/archive/2026/05/20260515-193100-gke-runtime-reaper-pft-v2-amber.md`.

### Internet → Postgres → GCS tutorial validation (2026-05-15)

- New runnable tutorial playbooks live in `repos/e2e` under
  `fixtures/playbooks/tutorials/internet_postgres_gcs/`:
  `internet_postgres_gcs_hmac.yaml` and
  `internet_postgres_gcs_workload_identity.yaml`.
- New user-facing tutorial lives in `repos/docs`:
  `docs/tutorials/09-internet-postgres-gcs.md`. It covers credential
  registration, playbook registration, execution, status checks, and
  expected results for local kind and GKE.
- GKE demo validation used NoETL API `http://127.0.0.1:18082`,
  Postgres credential `pg_k8s`, HMAC credential `gcs_hmac_local`,
  Workload Identity bucket `noetl-demo-output`, and HMAC bucket
  `noetl-demo-19700101`.
- Fresh GKE executions completed successfully:
  Workload Identity execution `627592523359191239` wrote
  `gs://noetl-demo-output/noetl/tutorial/demo-workload-identity/github_repo_627592523359191239.csv`;
  HMAC execution `627592528442687692` wrote
  `gs://noetl-demo-19700101/noetl/tutorial/demo-hmac/github_repo_627592528442687692.csv`.
  Command-table validation showed every command row `COMPLETED` with
  `error = null`.

### File-based cross-agent handoff convention (2026-05-15)

- New `handoffs/` tree codifies how Claude / Codex / Cursor / Gemini /
  any future agent pass work to each other through files rather than
  chat. Threads live at `handoffs/active/<YYYY-MM-DD-slug>/` as
  numbered `round-NN-prompt.md` + `round-NN-result.md` pairs with
  YAML frontmatter (`thread / round / from / to / status`). Closed
  threads move verbatim to `handoffs/archive/`.
- Two slash commands: `/handoff-open <slug> "<description>"`
  (dispatcher) and `/handoff-result <slug>` (executor).
- Behavioral rules: `agents/rules/handoffs.md`. Full convention with
  per-tool enter/exit instructions: `handoffs/README.md` and the
  matching section in the root `README.md`.

### Travel agent + AI OS platform (durable, arc closed 2026-05-13)

- **Travel agent flagship** closed GREEN end-to-end on GKE
  (2026-05-10): three-phase arc proved the "MCP is just a playbook"
  thesis. Phase 1 — widget flagship (9 design rules pinned in
  `repos/docs/docs/reference/playbook_authoring_guide.md`). Phase 2 —
  Amadeus calls routed through `automation/agents/mcp/amadeus` via
  `tool: agent framework: noetl`. Phase 3 — Vertex AI as third
  provider via `automation/agents/mcp/vertex-ai`. All three intents
  validated GREEN on GKE with `effective_provider=vertex-ai`, no
  fallback. Travel runtime is catalog v2 (id `623381857714832176`).
- Travel domain renamed from `muno` to `travel`. The travel app runs
  on Cloudflare Pages at `https://travel.mestumre.dev` with
  Cloudflare Access in front and Auth0 for end-user auth.
- Cloudflare edge stack for the GUI/Gateway split is documented and
  automated in `repos/ops/automation/cloudflare/gke_gateway_edge.yaml`
  + `repos/docs/docs/operations/cloudflare-pages-gui-tunnel-gateway.md`.

### MCP-as-agent-playbook architecture (durable, shipped April–May 2026)

- `noetl/noetl v2.25.0+` exposes `noetl.server.api.mcp` with
  `POST /api/mcp/{path}/lifecycle/{verb}`,
  `POST /api/mcp/{path}/discover`, and
  `GET /api/catalog/{path}/ui_schema`. MCP servers are first-class
  catalog resources managed by lifecycle agent playbooks.
- `repos/ops/automation/agents/kubernetes/` holds the runtime +
  lifecycle agent fleet. The GUI run-dialog (`noetl/gui v1.2.0+`)
  uses `/api/catalog/{path}/ui_schema` to render workload forms per
  catalog row.
- Kubernetes MCP terminal commands are routed through the
  Kubernetes runtime agent (no direct browser → MCP calls).

### DSL v2 baseline (durable, shipped March–April 2026)

- All fixture playbooks migrated to canonical DSL v2
  (`input` / `output` / `set` / `next.arcs[].set`). The legacy
  field names (`args`, `outcome`, `set_ctx`, `set_iter`,
  `next.arcs[].args`) are retired.
- See "DSL Refactoring Reference Documents" below for the spec docs
  every agent must follow when authoring or refactoring playbooks.

### v2 distributed-runtime spec (durable, all 7 phases done 2026-05-23)

**All seven phases of the v2 distributed-runtime spec are complete
as of NoETL v2.99.0 (2026-05-23 close-out).** Any audit table that
still shows phases as "partial" or "not started" is stale and
predates the close-out session.

Per-phase status + closing PR(s):

| Phase | Topic | Closing PR(s) |
|---|---|---|
| 0 | Instrumentation + stage/frame tables + replay API | `#435` … `#550` |
| 1 | Frame-shaped cursor loops | `#585` |
| 2 | Projector StatefulSet behind NATS durable consumers | predates close-out |
| 3 | Apache Arrow IPC Tier 1.5 + shared-memory cache | `#587` (observability); cache + IpcHint + producer/consumer wiring landed earlier |
| 4 | URN + KEDA + NATS supercluster | `#593` + `#594` + `#595` (+ `#596`/`#597` fixes) |
| 5 | Port/adapter event/projection/payload (filesystem + S3 + GCS + Azure) | `#582` … `#592` (6 rounds) |
| 6 | Stage planner for fanout/reduce | `#588` |

**Source of truth** for the audit:
[`repos/docs/docs/features/noetl_distributed_runtime_spec.md`](https://github.com/noetl/docs/blob/main/docs/features/noetl_distributed_runtime_spec.md)
§ 0 ("Status — all seven phases done") + the archived memory entry
`memory/archive/2026/05/20260523-051829-v2-distributed-runtime-spec-complete-all-seven-phases-done.md`.

**Phase 3 specifically** (the recurring stale claim):

- `ArrowIpcSharedMemoryCache` —
  [`noetl/core/storage/ipc_cache.py`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/ipc_cache.py)
  (256-MiB default budget, LRU-by-lease eviction).
- `IpcHint` model —
  [`noetl/core/storage/models.py:93`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/models.py).
- Producer wiring: `cursor_worker.py` stages frame outputs in IPC
  cache + durable tier (commit `2d27911e`).
- Consumer fast-path: `TempStore.get_ipc_bytes` with graceful
  fallback (expired hint / cross-node / segment evicted).
- Observability: 7 Prometheus counters + `summary["ipc"]` block on
  the projector (PR #587, commit `20071316`).
- Wiki: [`noetl/core/storage.md`](https://github.com/noetl/noetl/wiki/storage)
  has a "Tier 1.5 — IPC shared-memory cache" section that
  documents the design end-to-end.

**Open architectural follow-ups beyond the v2 spec** (explicitly
out-of-scope for the spec — these are product-layer work on top):

- Catalog-driven query routing (URN → cluster endpoint).
- Cluster-aware NATS client routing (`NATSCommandPublisher` picking
  endpoint per URN locality).
- Per-tenant NATS accounts in the supercluster generator.
- Cross-cluster JetStream stream mirror/source.
- Storage-tier spill path actually routing through a registered
  `PayloadStore` (closes the gap between Phase 5 and existing
  `TempStore` callers).
- Replay path resolving `s3://` / `gs://` / `azure://` URIs through
  the registered adapter.
- Process-emulator compliance fixture (Azurite + fake-gcs-server)
  so GCS + Azure cloud adapters join the parametrized compliance
  suite.

None of these are v2-spec blockers — they're the chemistry-lab-
cloud product layer.

## DSL Refactoring Reference Documents

Authoritative for any DSL refactoring work:

- **Assignment and Reference Spec** —
  `docs/features/noetl_dsl_assignment_and_reference_spec.md` in
  `noetl/docs`. Defines `set`, scope model (`workload`, `ctx`, `step`,
  `iter`, `input`, `output`), `_ref` naming rules, reference object
  contract, cross-step propagation.
- **DSL Refactoring Spec** —
  `docs/features/noetl_dsl_refactoring_spec.md` in `noetl/docs`.
  Defines the target model (`workflow`, `step`, `tool`, `input`,
  `output`, `set`, `spec`, `next`) and migration map.

**Key rules:**

1. Replace `args` with `input`, `outcome` with `output`,
   `set_ctx` / `set_iter` with `set`.
2. `set` is top-level (never under `spec`).
3. `_ref` suffix required for unresolved references; hydrated data
   must not use `_ref`.
4. Cross-step data via `set` + consumer `input`, not
   `next.arcs[].args`.
5. Workers do not synthesize nodes; the server is the sole routing
   authority.

## Recent Compaction

- 2026-05-15 — `memory/compactions/20260515-173703.md` archived 244
  inbox entries spanning 2026-04-07 → 2026-05-15. Cleared the
  pre-runtime-reaper backlog.

## Open Items

### Unpushed local ai-meta commits (awaiting human review/push)

- `61203b3 docs(agents): add file-based cross-agent handoff convention`
- `9294b55 chore(sync): bump doctor to 002b118`
- `84e7d46 chore(sync): bump doctor for cli 2.14.2 default`
- `1265258 chore(sync): bump cli, doctor for release assets`
- `f5e60a0` and `6a635d8` in `repos/doctor` were merged via
  `noetl/doctor#5` and are reflected in pointer `9294b55`.

### Operational follow-ups

- **MDS=0 caveat resolved by 2026-05-15 PFT v2 run.** The 2026-05-14
  PFT v2 rerun had reported `mds_expected=0` because the local test
  server was freshly seeded; the 2026-05-15 rerun on the new image
  exercised the full MDS path and the in-process reaper recovered the
  expected orphan batches. No further action.
- **Travel arc**: no in-flight items; treat as durable baseline.
  New travel work opens fresh sync notes under
  `sync/issues/YYYY-MM-DD-*.md`.
- **Logging hygiene rule** (`agents/rules/logging.md`) still
  load-bearing; honor it on any new endpoint that runs on a
  high-frequency poll.

### Conventions to honor

- When a task spans more than one AI session, use a file-based
  handoff (`handoffs/active/<slug>/`) instead of pasting briefs into
  chat. See `handoffs/README.md`.
- NoETL release commit subjects use no scope braces
  (`fix: ...`, not `fix(scope): ...`) so semantic-release
  automation triggers correctly.

## Compaction 2026-03-03T19:25:41Z

- Source: `memory/compactions/20260303-192541.md`
- Entries compacted:
- ai-meta memory system enabled

## Compaction 2026-03-17T18:18:21Z

- Source: `memory/compactions/20260317-181821.md`
- Entries compacted:
- noetl issue 244 lease expiry
- issue 244 fix started
- Kind redeploy via ops playbook
- Issue 244 regression retest on kind
- Issue 244 same-worker replay patch
- Remove pages integration from noetl monorepo
- Issue 246 parallel batching validation
- Issue 244 regression PR247
- Issue 244 regression executed on kind
- PR247 copilot feedback applied
- ops gke deploy defaults to published v2.8.9
- gke pending rollout mitigated via strategy patch
- ops noetl rollout strategy persisted
- ops deploy validated persistent surge-free rollout
- batch acceptance timeout issue opened
- issue 249 async batch acceptance implemented
- issue 251 readiness-gated recovery implemented
- issue 251 log flood suppression follow-up
- agent-orchestration-guide
- docs-ai-meta-section
- Issue 253 transient playbook retries + kind redeploy
- Issue 255 stale in-memory issued_steps cache invalidated on command commit failure
- Deployed NoETL v2.10.2 to GKE noetl-cluster via ops gke playbook
- gcp cost controls applied with reusable scripts
- ai-agent-template created
- GKE gateway login failed-to-fetch recovered by NATS stream reset
- agent orchestration adk langchain bridge implemented
- agent orchestration docs synced to implementation
- published noetl v2.10.3 and removed in-repo automation tree
- NoETL v2.10.3 local+gke deploy and amadeus token smoke validation
- Kind redeploy finalization after context correction
- Gateway login outage after wrong-context local playbook apply
- CUDA-Q playbook landed
- issue-259-memory-leak-audit-started
- pr260-follow-up-tempstore-env-docs-and-ops
- tempstore-env-docs-ops-prs-opened
- v2-10-5-deployed-kind-and-gke-submodules-reset-main-master
- AHM-4280..4284 mirrored to noetl/noetl issues
- AHM-4280..4284 implementation pushed
- noetl commit subject format for automation
- AHM-4280..4284 moved to Testing with PR 266
- PR266 copilot findings fixed
- PR266 second copilot validation pass fixed
- noetl pr266 follow-up fixes landed
- pr266 latest copilot validation resolved
- noetl pr266 merged to master
- v2.10.6 deployed to kind-noetl, promotion blocked
- Execution protocol + crate bump sync

## Compaction 2026-04-02T18:30:17Z

- Source: `memory/compactions/20260402-183017.md`
- Entries compacted:
- Crates 2.8.8 published
- NoETL PR271 finalize/dead-end completion fix
- NoETL v2.10.10 rolled out to GKE and project org note
- deployed-noetl-v2-10-14-to-gke-using-ops-playbook
- ahm-4316-4318-4320-4322-loop-stall-and-postgres-transient-fixes-started
- NoETL v2.10.15 deployed to GKE via ops playbook
- CLI gateway auth flow + console REPL implemented
- CLI browser/device login flow pushed for gateway auth
- CLI PKCE localhost callback auth mode implemented
- noetl issue 345 asyncio blocking refactor
- noetl issue 345 asyncio fix implemented
- noetl PR #346 merged as v2.13.1
- noetl codex runtime program started
- docs cli section split started and github issue creation blocked
- created cli and gateway codex runtime issues project blocked by token scopes
- created noetl ai runtime github project and linked issues
- cli m1 codex integration implementation started
- project statuses updated and gateway m1 started with pr6
- noetl load test benchmark kind cluster
- dsl fixture refactor started in pagination playbooks
- dsl fixture refactor aligned to pr347 completed
- DSL fixture runtime validation blocked by server `cmd.args` regression
- Runtime input/context consistency fix after PR #348
- Kind LAN Hostname Exposure (noetl) - 2026-03-28
- DSL Loop Replay Fix + Runtime Validation (PR #354)
- Over-dispatch/replay tracking updated with tooling matrix repro
- CLI v2.13.0 + Ops Sync + Binary Baseline Refresh
- noetl-pft-flow-mds-investigation-2026-04-02

## Compaction 2026-04-06T10:34:34Z

- Source: `memory/compactions/20260406-103434.md`
- Entries compacted:
- Added GEMINI.md files and updated root instructions
## Compaction 2026-05-15T17:37:03Z

- Source: `memory/compactions/20260515-173703.md`
- Entries compacted:
- tooling_non_blocking probe execution
- Status parity and state load fixes
- Validate PR 375 and multi-pass loop deduplication
- E2E Deployment and PR 375 Verification
- Persist loop payloads PR 376
- test_pft_flow Metrics Analysis
- residual-debug-traces-removed
- status-api-fix-completed
- loop.done race fix
- Refactor nested engine and stabilize loop execution
- Optimize server batch throughput and fix replay tests
- Worker item pipeline execution time optimized
- Removed O(N^2) SQL parsing bottlenecks
- Worker item pipeline optimization merged
- Fix regex bug in Postgres SQL parser
- Local deployment and validation of v2.17.20
- Eliminated array-based state bloat in engine
- Loop reconciliation queries optimized from 1410ms to 3ms
- Optimize worker initial event bounds
- test_pft_flow execution 604876797720658689 tracking
- NoETL Distributed Processing Enhancement Plan
- Engine Pipeline Stabilization & Loop Re-sync
- Phase 0 Refactor: Correctness and Deduplication
- Phase 1 Refactor: Schema and Storage Layer
- Colima Migration + Envelope Validator Fix Deployed
- Data Plane Separation + Distributed Loop Fix Chain (April 17 2026)
- state-refactor-pushed-and-rerun-request
- status parity and trigger cleanup
- engine internals doc moved to docs and minio guidance
- Command table write-path gap
- pft perf fixes and fresh test 608606943497683474
- minio local provisioning and storage guidance integration
- pft performance and reliability fixes
- minio local setup documentation
- phase-0 RisingWave storage alignment landed
- podman runtime migration + phase-0 validated + phase-1 branch opened
- phase-1 DiskCacheBackend landed with two-pool split and cloud spill
- phase-1 validation: end-to-end disk + MinIO spill green
- PFT injected SYNTAX_ERROR fixture removed; facility 1 1000/1000 green
- PFT parallel DAG + command hash-partition migration drafted
- command_id BIGINT refactor + hash partitioning applied
- barrier-4 stall root cause: reference-only envelopes + strict arc eval
- PFT redeploy session — multiple engine fixes, test still not green
- PFT v105 partial success — barriers fire, fetch loop.done race remains
- PFT v108 green=1/10 — wait_for_all_barriers works; facility 2 hits fetch-loop stuck claims
- cursor-loop infrastructure complete phases 1-5
- cursor-loop infrastructure landed; PFT multi-facility race remains
- row-preservation fix unblocks ctx.facility_mapping_id threading; multi-facility cursor loops green
- PFT cursor run blocked on MDS child command pending backlog
- PFT 10/10 GREEN — cursor-loop + MDS max_in_flight fix
- PR #383 merged to noetl main — cursor-loop shipped
- Ops GHCR deploy playbooks merged
- GUI terminal workspace, e2e split, typed execution, and GHCR deploy flow
- GUI Kubernetes MCP deployed and verified
- Codex submodule refresh and PFT execution rerun on kind
- MDS batch worker end step template not hydrated after loop.done
- PFT clean rerun — MDS end-step fix validated, facilities 1 and 2 GO
- GUI quiet nginx + frontend login-related logs
- Bumped e2e + gui pointers after PRs merged
- Deploy latest releases to kind + nushell-style theme branch
- Phase 1 — MCP lifecycle / discover / ui_schema PR #392
- PR #392 merged as v2.25.0; follow-up #393 + GUI Phase 4 PR queued
- Phase 3 — ops MCP lifecycle agent fleet (PR #15)
- Phase 2 merged + pointers bumped + lifecycle agents registered
- MCP architecture verified end-to-end on kind v2.27.0
- MCP architecture end-to-end on kind: pod Running, GUI showing it
- GKE Gateway Auth0 login repair
- GKE private GUI deployment profile live
- Cloudflare Pages GUI and Cloud Run Gateway runbook merged
- Cloudflare Tunnel for GKE Gateway docs merged
- Cloudflare GKE edge deployment playbook merged
- Session refresh after cleanup-repo bumps
- Rust CLI distribution cleanup
- 2026-05-04 — Spike Gaps 2 + 5 merged
- 2026-05-04 — Spike additions audited for optional-dependency contract
- 2026-05-04 — Claude ↔ Codex bridge: first round-trip
- 2026-05-05 — Autonomous Codex deploy + spike smoke (AMBER outcome, 6 findings)
- 20260505-153729-gap1-carveout-tool-error.md
- 20260505-163002-gap41-spike-green-with-followups.md
- 20260505-191122-v2358-regression-sweep-amber.md
- 20260505-211618-three-followups-green.md
- 20260505-220055-full-regression-gemma4-amber.md
- 20260506-032648-docs-only-green.md
- Today (in-cluster Ollama):
- repos/e2e/fixtures/playbooks/spike/spike_e2e_test.yaml (post-#9)
- 20260506-060840-gke-vertex-amber-model-availability.md
- 20260506-153850-arc-closed-gke-vertex-production.md
- 20260506-163551-worker-key-forwarding-green.md
- 20260506-213402-alias-removal-green.md
- 20260507-010751-arc-closed-amber-tail-latency.md
- 20260507-023206-adaptive-backoff-amber-projection-deep-nested.md
- 20260507-035806-projection-recursive-green-audit-vindicated.md
- 20260507-221619-pft-action-batch-local-kind-green.md
- GUI: chatui-aligned widget renderer for NoetlPrompt (round 2)
- AI-OS round 2 widget renderer handed to Codex for local kind deploy
- noetl render projection allow-path round 2 unblock
- AI-OS round 2 GREEN — widget renderer + render projection + e2e all-widget coverage
- Handed AI-OS docs text pass to Codex (post-round-2 polish)
- Docs widget tutorial deployed + local LAN access note
- Widget LAN access + visibility handover to Claude
- GUI LAN auto-rewrite + run auto-render widgets — round 2.x design + handoff
- GUI LAN auto-rewrite + run auto-render widgets — GREEN
- Round 2.x GREEN — GUI LAN auto-rewrite + run auto-render shipped
- Round 2.x.1 designed widgets-everywhere — handoff to Codex
- Travel agent + Amadeus MCP + tutorial designed — flagship widget demo handoff
- Travel agent flagship AMBER — audit SQL runtime blocker
- Travel agent flagship AMBER — log_classification SQL fix designed and handed to Codex
- Travel agent AMBER-to-GREEN round remains AMBER — SQL fixed, Amadeus/keychain path next
- Travel keychain bare-refs fix designed — AMBER round 2 to GREEN handoff
- Travel keychain round AMBER — token binding fixed, Amadeus upstream/error handling remains
- Travel + Amadeus MCP urllib wrappers designed — AMBER round 3 to GREEN handoff
- Travel urllib round AMBER — MCP green, travel friendly-error renderer still marks failed
- Travel render-failure ok-status fix designed — AMBER round 4 to GREEN (one-line)
- Travel failure-status fix backend-green, UI still AMBER
- Travel render-bubble + canvas wiring designed — AMBER round 5 to GREEN
- Travel render bubble still AMBER — final tail cannot see selected render
- Travel render_X-as-tail designed — AMBER round 6 to GREEN
- Travel render tail terminal GREEN, canvas AMBER
- Canvas form-submit + report formatter polish designed — AMBER round 7 to GREEN
- Canvas form-submit fixed; widget rerun button remains AMBER
- Travel canvas widget rerun GREEN
- Travel agent flagship round CLOSED GREEN — full arc retrospective
- Handed playbook authoring guide to Codex — pin 11 rules from 9-round travel agent arc
- Playbook authoring guide GREEN — 11 rules pinned, flagship arc fully closed
- Handed travel multi-provider Anthropic round to Codex
- Handed travel Anthropic re-smoke to Codex — pending GCP secret provisioning
- Handed travel-via-Amadeus-MCP Phase 2 to Codex
- Phase 2 GREEN — travel agent uses Amadeus MCP playbook internally
- Handed travel vertex-ai Phase 3 to Codex (third provider via MCP playbook hop)
- Travel agent vertex-ai Phase 3 — AMBER (code GREEN, GCP auth blocker)
- Travel agent vertex-ai Phase 3 closes GREEN — three-provider flagship complete
- Handed authoring-guide workload-defaults rule to Codex (12th rule from the flagship arc)
- Handed travel hotels/activities round to Codex (closes Phase 1 stub)
- Travel hotels/activities round closes GREEN — four-branch travel agent live
- Handed travel app:form refinement round to Codex (3 PRs: gui + ops + docs)
- Travel app:form refinement round closes GREEN — refinement UX live in canvas + terminal
- Handed travel render-audit side-effect round to Codex (executes the round 6 forward-pointer)
- Travel render-audit side-effect round closes GREEN — round 6 forward-pointer executed
- Handed travel Anthropic re-smoke v2 to Codex (refreshed for post-Phase-3 state)
- Travel Anthropic re-smoke v2 AMBER - secret fixed, model access mismatch
- Handed travel Ollama Phase 4 to Codex (fourth provider via new mcp/ollama playbook)
- Travel Ollama Phase 4 closes GREEN — multi-provider arc reaches its cap
- Amadeus 500 investigation closed - sandbox/service-side verdict
- Handed Amadeus test API 500 investigation to Codex (diagnostic round)
- Handed authoring-guide python-globals rule to Codex (13th rule from the travel arc)
- Handed classifier prompt single-source refactor to Codex (load-bearing debt cleanup)
- Classifier prompt single-source refactor closes GREEN — full deferred-list retrospective
- Handed travel Anthropic model flip to Codex (Path A — minimum diff to GREEN)
- Travel Anthropic model flip closes GREEN — four-provider arc fully shipping
- Handed travel Path B + tutorial 08 to Codex (final architectural-purity round + ship docs)
- Path B + Tutorial 08 close GREEN — ops+docs arc reaches full completion
- Handed noetl agent → MCP result hydration fix to Codex (engine round — Claude coded, Codex verifies + deploys)
- Noetl agent result hydration closes GREEN — entire deferred list cleared
- 2026-05-11 — GKE parity sync closed AMBER
- Handed GKE parity sync round to Codex (config + deploy + audit)
- GKE parity sync closes AMBER — catalog + engine parity fixed; GUI gap + storage tier finding
- MinIO eliminated; SeaweedFS/RustFS chooser AMBER
- 2026-05-11 — Gateway terminal surface traced to Cloudflare Pages, deploy blocked on token
- Handed Path A — gateway terminal surface trace + gui v1.11.0 bump to Codex
- Handed MinIO elimination + SeaweedFS/RustFS chooser round to Codex
- MinIO elimination round closes AMBER — local GREEN, noetl PR blocked on review, GKE deferred
- Handed object-store chooser GKE rollout to Codex (closes MinIO-elimination AMBER)
- Object-store chooser GKE rollout GREEN
- Handed travel runtime workaround cleanup to Codex (post-v2.37.8 belt-and-suspenders removal)
- Travel hydration workaround cleanup GREEN
- Authoring guide kind-to-GKE parity rule GREEN
- Queued four remaining deferred rounds for Codex (session wind-down)
- Ollama bridge on GKE option A GREEN
- Amadeus production API switch code-only GREEN
- Cloud-tier router decision GREEN
- GKE cloud spill tier switched to GCS
- Handed cloud-tier GCS implementation on GKE to Codex (Round D execution)
- Handed Ollama backend provisioning on GKE to Codex (Round B option A → option B)
- Ollama backend on GKE provisioned
- Handed Amadeus production credentials + smoke to Codex (closes Round C)
- Handed Google Places enrichment round to Codex (opt-in supplementary layer, Pattern C hybrid auth, free-tier disciplined)
- Pattern C precondition state: GKE wired correctly; kind worker pod has separate ADC blocker
- Ollama backend on GKE stopped for cost control
- SeaweedFS object store on GKE stopped for cost control
- Google Places enrichment AMBER, activities GREEN
- Handed Duffel flights MCP integration to Codex (search-only, default duffel, test env, non-breaking opt-out to amadeus)
- Duffel flights MCP GREEN
- Duffel test orders GREEN
- Handed Duffel test-env order creation tools to Codex (Round 1 of trip-planner project)
- Duffel Stays unavailable on test account — Round 2 closed, hotels source stays Amadeus
- Handed Firestore MCP + event-sourcing tools + replay helper to Codex (trip-planner Round 3)
- Firestore MCP event-sourcing GREEN
- Handed muno bootstrap + widget contract to Codex (trip-planner Round 4a/6a)
- Muno bootstrap widget contract AMBER
- muno bootstrap container build — AMBER (bash missing in alpine)
- muno bootstrap container build — GREEN
- Handed LLM-driven itinerary agent to Codex (trip-planner Round 4b)
- Muno itinerary agent 4b GREEN
- Handed real Material widget components to Codex (trip-planner Round 6b)
- Muno Material widgets 6b GREEN
- Firestore calendar view Round 5 GREEN
- Handed Firestore-backed calendar view to Codex (trip-planner Round 5 — RESHAPED)
- Handed end-to-end trip-planner tutorial to Codex (trip-planner Round 7 — cap-stone)
- 2026-05-13 — Tutorial 08 end-to-end trip-planner capstone GREEN
- Handed muno deployment + Auth0 to Codex (post-tutorial Round 8)
- 2026-05-13 — Muno Auth0 deploy AMBER at pre-handoff
- Muno Auth0 Deploy — DNS Handoff
- Muno GKE UI Removed
- Muno Cloudflare Pages CI
- Trip-Planner Repo Renamed to Travel
- Travel Public Domain Rename
- Travel Pages + Auth0 stage report
- Cloudflare Access travel AMBER — pre-handoff secrets missing
- Handed Cloudflare Access protection of travel.mestumre.dev to Codex (URGENT — Round 9)
- Supersede — Cloudflare Access Round 9 cancelled, replaced by gateway-session Round 9'
- Travel gateway-session auth AMBER pending browser smoke
- Travel gateway-link timeout hotfix
- Travel mirrors GUI Auth0 hash-token flow
- Handed travel gateway-session auth to Codex (Round 9 corrected — supersedes Cloudflare Access plan)
- Travel gateway CORS tunnel hotfix
- Travel Auth0 audience hotfix
- Handed travel v1 UX polish to Codex (Round 10 — first post-Round-9 functional iteration)
- Travel v1 UX polish AMBER preflight
- Travel v1 UX polish shipped, pending browser smoke
- 2026-05-13 — Travel shell submit/menu hotfix GREEN
- Handed travel PropertyBlock full slot surfacing to Codex (Round 11)
- 2026-05-13 — Travel PropertyBlock full slot surfacing GREEN pending browser smoke
- 2026-05-13 — Travel itinerary catalog path hotfix GREEN
- 2026-05-13 — Travel cancel planning request GREEN
- Travel itinerary callback result hotfix GREEN
- Travel itinerary Gateway callback hotfix GREEN
- Travel place_list null rating hotfix GREEN
- Travel place result layout polish GREEN
- Travel place selection state GREEN
- Travel slot-state loader hotfix GREEN
- Travel Duffel flight contract hotfix GREEN
- Travel gateway auth fail-fast and self-cleanup
- Travel callback timeout poll fallback shipped
- Travel gateway NoETL API polling fix shipped
- Travel terminal event payload extraction shipped
- Travel full widget envelope event extraction shipped
- Travel fetches enough execution events for widget extraction
- Travel itinerary helper scope fix shipped
- Travel flight CTA order routing fix
- GKE paginated-api HPA
- Travel Duffel order passenger fix
- NoETL command reaper self-healing handoff
- NoETL command reaper + repos/doctor runtime reaper scaffold
- Runtime reaper documentation refresh after PFT v2 green

## Compaction 2026-05-23T05:25:25Z

- Source: `memory/compactions/20260523-052525.md`
- Entries compacted:
- Tutorial arc closed + post-amber cleanup PRs merged
- GKE gateway CORS regression dropped travel.mestumre.dev
- Travel booking unblocked - phone + calendar persist chain
- Booking widget envelope empty - cross-step scope erosion on first_widget
- Travel View full order CTA routed to hotel search
- Travel order_confirmation widget upgraded to inline expand + PDF link
- Travel order_confirmation null document_url crashed widget validator
- Travel sidebar history + new search button shipped
- Distributed runtime + event store v2 spec authored
- mermaid-diagram-support
- GLUT memory ownership rule
- Wiki maintenance rule landed
- v2 distributed-runtime spec — Phase 1 (frame projections) landed
- v2 distributed-runtime spec — Phase 6 (stage-planner wiring) landed
- v2 spec Phase 3 audit refreshed + IPC observability landed
- v2 spec Phase 5 round 1 — payload-store port landed
- v2 spec Phase 5 round 2 — S3 payload-store adapter landed
- v2 spec Phase 5 round 3 — GCS payload-store adapter landed
- v2 spec Phase 5 round 4 — Azure Blob payload-store adapter + SeaweedFS docs landed
- v2 spec Phase 5 complete — port/adapter event/projection/payload
- v2 spec Phase 4 round 1 — URN extension landed
- v2 spec Phase 4 round 2 — KEDA scaler landed
- v2 distributed-runtime spec complete — all seven phases done

## Compaction 2026-05-24T00:20:05Z

- Source: `memory/compactions/20260524-002005.md`
- Entries compacted:
- Phase 4 round 3 live-kind validation — three NATS supercluster bugs caught + fixed (PR #596)
- Scope A — KEDA + NATS supercluster manifests moved from noetl to ops repo
- Two-wiki convention codified — noetl/noetl wiki + noetl/ops wiki
- Scope B — ci/manifests fully consolidated into noetl/ops
- Scope B post-validation — fresh kind redeploy + KEDA + supercluster + playbook smoke
- Operator-friendliness fixes + v2-spec close-out doc + GKE handoff prepared
- GKE provision validation — codex report received; live stack diverges from ops-manifest assumption
- noetl-worker consumer-drift root-caused — recovery in PR #600
- noetl#600 merged — worker consumer-drift fix shipped in v2.100.3

## Compaction 2026-05-24T05:51:40Z

- Source: `memory/compactions/20260524-055140.md`
- Entries compacted:
- noetl#601 merged — NATS URL credential redaction shipped in v2.100.4
- noetl#602 merged — catalog scope semantic fix shipped in v2.100.5
- v2.100.5 deployed to GKE — all three fixes verified live; HPA conflict surfaced
- GKE worker HPA conflict resolved — playbook default flipped, cluster patched
- KEDA ScaledObject promoted to chart-templated NATS-JetStream artifact (GKE Option A)
- Writing-style preference: never use the word 'canonical'
- GKE Helm install wiki page published; manifests-keda clarified for kind vs GKE profile
- Drove items #4/#5/#2/#3 of GKE Option-A follow-up list (PR #117 + wiki commit e0a9b4e)
- Archived two stale-active handoff threads (shared-memory docs + pluggable-deps)

## Compaction 2026-05-26T06:33:33Z

- Source: `memory/compactions/20260526-063333.md`
- Entries compacted:
- Production auth+travel login incident — cluster-side mitigations applied (gateway timeout, worker min replicas)
- Codified ephemeral-blueprints execution model (architecture + agent rule)
- Travel wiki bootstrap + docs/gateway/travel pointer bumps + thread archive
- Wikis bootstrapped for all six remaining production submodules; gateway gets v2.11.0 coverage
- Travel itinerary-planner consolidation closed; ops + travel + both wikis bumped
- Keychain leak redaction shipped — noetl/noetl#603 merged, noetl bumped to fb38b07f
- Storage-side credential hygiene Round A shipped — noetl/noetl#604 merged, v2.100.7 cut
- Credential refs Round B shipped — noetl/noetl#605 merged
- Executions-listing stale-status fix opened as noetl/noetl#606; noetl bumped to v2.100.8
- Platform step-overhead: case-action emit batching shipped as noetl/noetl#607 (small win)
- Case-action emit batching shipped: noetl/noetl#607 merged; bumped to v2.100.10 (covers #606 + #607)
- Inline trivial children Round A shipped: noetl/noetl#608 merged
- Live dry-run enabled on GKE + visibility fix opened as noetl/noetl#609
- Inline-decision event-log visibility verified end-to-end on GKE; detector finding to investigate
- Inline-execution detector catalog fallback opened as noetl/noetl#610
- Inline detector catalog fallback verified live on GKE; signal is real
- Catalog-lookup cache opened as noetl/noetl#611 to restore dry-run perf
- Catalog cache live-verified: per-turn 39s -> 7s cold / 4s warm; signal correct

## Compaction 2026-05-29T02:41:39Z

- Source: `memory/compactions/20260529-024139.md`
- Entries compacted:
- inline-execution Round B merged — PR #612 lands worker inline runner
- Round B Phase D found pre-existing catalog version=latest bug — runner never fires on GKE
- Catalog version=latest 404 fix merged — noetl PR #613
- Phase D re-run found uuid4 % 10**20 overflows bigint; inline runner result also degenerate
- Phase D v3 — Bug A fixed (bigint), Bug B confirmed independent (last-step result semantics)
- Bug B fix PR #615 — runner mirrors dispatched-path boundary-step filter
- Phase D v4 — Bug B fixed; vertex-ai-stub canned diagnosis flows; Bug C surfaced (cancel probe wrong endpoint)
- Round B Phase D complete — inline runner production-verified on GKE end-to-end
- Inline-execution chart-default PR opened on noetl/ops #119
- Inline-execution rolled out via chart on noetl-demo GKE — helm rev 171, durable across upgrades
- Production hotfix PR #617 — sanitize_sensitive_data was destroying credential aliases on cluster
- Production hotfix PR #617 merged + deployed — sanitize alias passthrough live on GKE
- Hotfix continuation #618 merged + deployed on GKE; wiki updated with two-tier redaction rule
- Production revert — flipped GKE worker to NOETL_INLINE_TRIVIAL_CHILDREN=off; itinerary-planner-class runner defects
- Runner event-emit fix open as PR #619 — strict payload schema + parent catalog_id wiring + silent-drop guard
- PR #619 deployed; SPA hang is pre-existing bug, opened handoff round-01
- SPA hang diagnosed + fix PRs open: noetl/gateway #12 + noetl/ops #120
- Gateway #12 + ops #120 merged + deployed; SPA hang fix live on GKE
- Massive session close-out: 9 PRs merged today; SPA hang now diagnosed to outbox arrow-feather vs gateway JSON; round-02 handoff prompt ready
- noetl v2.102.8 deployed (helm rev 175); outbox now JSON; chart template bug surfaced + PR #122 open
- Round 03 firestore subsystem removed + keychain resolution chain (3 PRs) + 10 ai-task issues closed
