# Current Memory

## Active Focus

- Maintain cross-repo orchestration quality and consistency.
- Keep submodule pointers aligned with merged upstream changes.
- Keep release/distribution workflows reproducible.
- **E2E fixture split landed** (April 2026): dedicated `noetl/e2e` repo now owns integration-test fixtures and docs; credential JSON templates may be committed, but local credential JSON values must remain uncommitted.
- **Execution observability typed and released** (April 26, 2026): `repos/noetl` release `v2.23.2` includes typed execution list/detail responses, AI explain fixes, and API review fixes. Remember `noetl.execution` is a projection; `noetl.command` + `noetl.event` are source-of-truth execution state tables together with the projection.
- **GUI terminal workspace shipped** (April 26, 2026): `repos/gui` release `v1.0.7` contains the terminal-first workspace, old Mac style theme, header/footer menus, runtime `/env-config.js` injection, direct/gateway API modes, resizable and maximizable terminal/dashboard panes, improved AI explain rendering, and Kubernetes MCP terminal commands.
- **Local kind GUI + MCP deploy baseline** (April 26, 2026): deployed `ghcr.io/noetl/gui:v1.0.7` to namespace `gui` using `repos/ops/automation/development/gui.yaml` with `action=deploy`, `image_pull_policy=Always`, `api_mode=direct`, `api_base_url=http://722-2.local:8082`, and `mcp_kubernetes_url=/mcp/kubernetes`; deployed `quay.io/containers/kubernetes_mcp_server:v0.0.61` to namespace `mcp` using `repos/ops/automation/development/mcp_kubernetes.yaml`.
- **Kubernetes MCP terminal verified** (April 26, 2026): browser validation at `http://localhost:38081/catalog` confirmed `mcp status` reports `kubernetes :: healthy url=/mcp/kubernetes tools=13`, `k8s namespaces` lists local kind namespaces, and `k8s pods mcp` returns the `kubernetes-mcp-server` pod `1/1 Running`.
- Track and drive fixes for Jira bug set `AHM-4280..AHM-4284` mirrored to `noetl/noetl` issues `#261..#265`.
- Enforce NoETL release commit subject format without scope braces (`fix: ...`, not `fix(scope): ...`) so automation triggers.
- Keep GCP project context explicit: `noetl-demo-19700101` is operated under Adiona.org organization context.
- **CLI + Ops cross-thread sync completed** (March 30, 2026 UTC): `noetl/cli` release `v2.13.0` published with asset `noetl-v2.13.0-darwin-arm64`; `repos/cli` is pinned at commit `fd4c3ee`, `repos/ops` at `9ce7924`, and `ai-meta` at `fa15612`.
- **Runtime binary baseline confirmed** (March 29, 2026 local): active local CLI path is `/Volumes/X10/dev/cargo/bin/noetl` and reports `noetl 2.13.0`; use this binary for ops/deploy/test automation commands.
- **DSL Refactoring in progress** (March 2026): Use the two canonical spec documents below as instructions when performing any NoETL DSL refactoring work.
- **DSL fixture migration execution started** (March 28, 2026): `repos/noetl/tests/fixtures/playbooks/pagination` migrated from legacy DSL fields (`args`, `outcome`, `set_ctx`, `set_iter`) toward target model (`input`, `output`, `set`) without touching Python source files.
- **DSL fixture migration aligned to PR #347 completed** (March 28, 2026): 126 fixture playbooks under `repos/noetl/tests/fixtures/playbooks/**` were migrated to canonical DSL v2 field/routing model (`input`, `output`, scoped `set`, arc `set`) and validated via full YAML parse + residual-pattern scan.
- **DSL runtime validation blocked post-PR #347 deploy** (March 28, 2026): local kind deploy + fixture registration succeeded (139/139), but distributed `/api/execute` currently fails with `"'Command' object has no attribute 'args'"` (server command context path still reading `cmd.args`), preventing end-to-end regression execution in cluster mode.
- **Runtime command-context fix prepared in PR #349** (March 28, 2026): server command emission now uses canonical `input` (with legacy `args` read alias), `cmd.args` crash path removed, and local kind validation confirms `/api/execute` starts distributed runs again.
- **Over-dispatch/replay tracked with live matrix repro** (March 29, 2026): updated `noetl/noetl#345` with fresh evidence from `tooling_non_blocking` fixture execution (`593446259529089845`) showing `run_duckdb_probe` over-dispatch (`issued=12`, expected `5`) while HTTP/Postgres remain `5/5`; separate runtime fix and unit tests prepared in `engine.py` + `tests/unit/dsl/v2/test_loop_parallel_dispatch.py`.
- **Tooling non-blocking matrix fixture added** (March 29, 2026): new fixture `tests/fixtures/playbooks/load_test/tooling_non_blocking/tooling_non_blocking.yaml` validates non-blocking overlap for core tools (`http`, `postgres`, `duckdb`) with optional probes for `snowflake`, `nats kv`, and `nats object store`, all in canonical DSL (`input`, `output`, `set`).
- **PR #352 opened for replay guard + tooling matrix** (March 29, 2026): https://github.com/noetl/noetl/pull/352 contains loop missing-index age-gating fix, targeted unit tests, restored async probe server behavior, and new tooling matrix fixture wiring.
- **Post-PR #352 replay/idempotency follow-up validated** (March 29, 2026): additional engine/API fixes prevent duplicate actionable event fan-out and reconstruct task-sequence loop progress from `call.done` during replay; live kind execution `593473735189856942` completed with core probes at expected counts (`issued=5`, `started=5`, `call.done=5` per step) and high concurrency (`max_parallel=5` for HTTP/Postgres/DuckDB in DB timeline).
- **Issue tracking updated** (March 29, 2026): `noetl/noetl#345` now includes the final post-fix execution evidence, SQL metrics, and validated non-blocking report for mandatory tooling probes.
- **test_pft_flow regression execution started** (April 14, 2026): execution `604876797720658689` launched against `tests/fixtures/playbooks/pft_flow_test/test_pft_flow` (catalog_id `604681050903544449`) on local kind cluster with NoETL image `local/noetl:2026-04-14-06-21`. Processes 1000 patients × 10 facilities with 5 sequential data types (assessments → conditions → medications → vital_signs → demographics). Status: RUNNING — assessments ✅ 1000/1000, conditions ✅ 1000/1000, medications ~38% in progress at last check, vital_signs/demographics pending, validation_log 0/10. GO criterion: validation_log = 10 rows with all 1000/1000 per facility.
- **Repo cleanup** (April 14, 2026): 3 one-off patch scripts from PR #352 work deleted from `scripts/ai_meta_tools/` (`fix_test_sql_assert.py`, `fix_worker_tests.py`, `time_test.py`). Notebook `tests/fixtures/playbooks/pft_flow_test/monitor_pft_execution.ipynb` outputs cleared + committed (`a25f098e` on noetl, `1a2de4b` on ai-meta). Both pushed to remote.

## DSL Refactoring Reference Documents

These documents are the authoritative instructions for the current DSL refactoring effort:

- **Assignment and Reference Spec** — `docs/features/noetl_dsl_assignment_and_reference_spec.md` in `noetl/docs` repo
  - Defines `set`, scope model (`workload`, `ctx`, `step`, `iter`, `input`, `output`), `_ref` naming rules, reference object contract, cross-step propagation patterns.
- **DSL Refactoring Spec** — `docs/features/noetl_dsl_refactoring_spec.md` in `noetl/docs` repo
  - Defines target DSL model: `workflow`, `step`, `tool`, `input`, `output`, `set`, `spec`, `next`. Migration map: `args`→`input`, `outcome`→`output`, `result`→`output.data`, `result_ref`→`output.ref`, `set_ctx`/`set_iter`→`set`, `next.arcs[].args`→`next.arcs[].set` or step-level `set`.

**Key refactoring rules (for AI execution):**
1. Replace `args` with `input`, `outcome` with `output`, `set_ctx`/`set_iter` with `set`
2. `set` is top-level (never under `spec`)
3. `_ref` suffix required for unresolved references; hydrated data must not use `_ref`
4. Cross-step data via `set` + consumer `input`, not `next.arcs[].args`
5. Workers do not synthesize nodes; server is sole routing authority

## Recent Compaction

- None yet.

## Open Items

- Sync Jira ticket summaries and acceptance criteria into GitHub issues `#261..#265`.
- Start implementation branches and PRs for each mirrored bug once reproduction details are confirmed.
- Run runtime validation for refactored fixture playbooks on local `noetl-kind` after building/deploying the post-PR #347 NoETL image.
- Unblock distributed runtime execution for DSL v2 by resolving server-side `cmd.args` attribute usage, then rerun regression playbooks on local `noetl-kind`.
- Merge `noetl/noetl` PR #349, redeploy promoted image, and complete full regression completion/failure summary capture.
- Deploy/redeploy image containing loop missing-index age-gating fix (`NOETL_TASKSEQ_LOOP_MISSING_MIN_AGE_SECONDS`) and rerun `tooling_non_blocking`; mandatory pass criteria: each core step has `issued_count==5`, `terminal_count==5`, `max_parallel>=2`.
- After core pass, enable optional probes (`snowflake`, `nats kv`, `nats object store`) in `tooling_non_blocking` workload and capture per-tool non-blocking report.
- Track status endpoint parity: `noetl status --json` can show `completion_inferred=true` with sparse `completed_steps` even when `/api/executions/{id}` is terminal/complete; decide whether to fix status reconstruction or rely on executions API for matrix reporting.
- Before any local redeploy/retest sequence, verify CLI baseline with `noetl --version` and require `2.13.0` (or newer approved release) to avoid mixing old `tool.args` behavior.
- **Complete test_pft_flow validation** (April 14, 2026): execution `604876797720658689` still RUNNING — wait for validation_log to reach 10/10. Run `monitor_pft_execution.ipynb` for GO/NO-GO report. On GO, mark `noetl/noetl` issues `#261..#265` (patient-loss race condition) as verified fixed.
- Extend MCP terminal integration beyond read-only Kubernetes observability after the `v1.0.7` baseline, keeping GUI commands safe-by-default and ops deployments playbook-driven.

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
