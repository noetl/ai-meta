# Current Memory

## Active Focus

- Maintain cross-repo orchestration quality and consistency.
- Keep submodule pointers aligned with merged upstream changes.
- Keep release/distribution workflows reproducible.
- **Codex cross-repo refresh + PFT rerun on kind** (April 28, 2026): ai-meta submodule pointers bumped to `repos/noetl` `f4c221af` (`v2.24.2-2-gf4c221af`, PRs #386–#390 covering MCP-as-playbook tooling, catalog agent discovery, embedded UI build removal, indexed execution observability, idempotent event constraint DDL), `repos/gateway` `635a4b0` (`v2.9.0-4`, agent execution contract refresh), `repos/gui` `e3bfea2` (`v1.1.1`, MCP terminal commands routed through agents + direct MCP proxy removed), and `repos/ops` `58db847` (Kubernetes runtime agent playbook, structured MCP agent args, GUI MCP proxy off by default). `repos/docs` pointer held at `88580e8` until feature branch `kadyapam/catalog-discovered-mcp-terminal-docs` (HEAD `e03707e`, 10 ahead of `origin/main` `519e707`) is merged upstream.
- **Local kind test API server live** (April 28, 2026): namespace `test-server`, pod `paginated-api-586794ddb5-dfv57` (1/1 Running), service `paginated-api.test-server.svc.cluster.local:5555`, NodePort `30555`; from inside the NoETL server pod `/health` returns `{"status":"ok"}` and the patient endpoint paginates correctly.
- **PFT regression rerun in flight** (April 28, 2026): execution `614768929377878676` for `tests/fixtures/playbooks/pft_flow_test/test_pft_flow` is RUNNING; test server logs show 200 OK calls from NoETL workers to `/api/v1/patient/assessments` and `/api/v1/patient/conditions`. Track to validation_log GO/NO-GO.
- **MDS batch worker `end` step renders `{{ start.* }}` literally after `loop.done`** (April 28, 2026): sub-playbook `tests/fixtures/playbooks/pft_flow_test/test_mds_batch_worker` execution `614782701987430447` reports `failed` in GUI v1.1.1 (`invalid literal for int() with base 10: '{{ start.batch_number }}'`) although the actual MDS HTTP fetch + Postgres saves completed. Same `start.*` refs render fine pre-loop. Sync issue + hypotheses + mitigation plan captured in `sync/issues/2026-04-28-bug-mds-batch-worker-end-step-template-hydration.md`.
- **PFT clean rerun — MDS end-step fix proven** (April 28, 2026): execution `614955937991754550` ran 21m21s on local kind via `http://722-2.local:8082` against patched sub-playbook v7. All 50 visible sub-execs COMPLETED, 0 FAILED — the `int()` literal-template error is gone. `pft_test_validation_log` shows facilities 1, 2, 3 all at GO criterion `1000/1000` for assessments / conditions / medications / vital_signs / demographics. Patient-loss race not triggering. Parent FAILED at facility 4 mid `run_mds_batch_workers` for an unrelated worker-pool/dispatch issue (only 3 workers ready, capacity 1 each, 208 offline zombies). Captured in `memory/inbox/2026/04/20260428-114722-pft-clean-rerun-...md`.
- **GUI login/nginx log noise reduced** (April 28, 2026): `repos/gui` branch `kadyapam/quiet-nginx-and-frontend-logs` at `79063db` silences `/env-config.js`, static-asset, `/favicon.ico`, `/robots.txt` access logs in nginx, drops the Axios interceptor 401 spam (which fired on every parallel poll during session expiry), and removes a leftover `🔍 PARSING PLAYBOOK CONTENT` console.log. `error_log` and meaningful warnings still surface. Local-only; push + bump ai-meta gitlink after PR merges.
- **e2e + gui pointers bumped after PRs merged** (April 28, 2026): `noetl/gui#13` and `noetl/e2e#3` merged. ai-meta gitlinks bumped to `repos/gui` `311ff96` (`v1.1.2`) and `repos/e2e` `3f7dcb3` via `0fb4c76 chore(sync): bump e2e, gui to merged SHAs`. Pushed to `origin/main`.
- **docs pointer bumped after merge** (April 28, 2026): `repos/docs` fast-forwarded to `35a778c` (`heads/main`) via `1c86b24 chore(sync): bump docs to merged SHAs`. All submodules now clean.
- **Latest releases redeployed to kind** (April 28, 2026): `noetl-server` and 3× `noetl-worker` running `ghcr.io/noetl/noetl:v2.24.2`; `noetl-gui` running `ghcr.io/noetl/gui:v1.1.2`. test-server + kubernetes-mcp-server survived. Smoke probes 200 across `/api/health`, `/api/executions`, `/`, `/catalog`, `/env-config.js`. New execution `615068195786850757` of `tests/fixtures/playbooks/pft_flow_test/test_pft_flow` is RUNNING cleanly with `run_mds_batch_workers` issuing/claiming/completing commands and `call.done` cycles healthy.
- **Nushell-style theme branch landed** (April 28, 2026): `repos/gui` topic branch `kadyapam/nushell-themes` at `4276931` rebuilds dark + light themes around a hybrid nushell.sh aesthetic (sans-serif chrome with mono terminal/data, slate-and-cream surfaces, type-tag tokens for shell-style structured values, gradient accent line under menubar, runtime context chip). Push to origin pending; PR + visual review next.
- **Theme PR #14 merged** (April 28, 2026): `noetl/gui#14` (nushell-style themes) opened and merged. Awaiting semantic-release `v1.1.3` cut on origin/main, then redeploy to kind. ai-meta `repos/gui` gitlink bump pending.
- **Catalog/MCP/UI architecture sketched** (April 28, 2026): `sync/issues/2026-04-28-architecture-mcp-catalog-and-friendly-playbook-launcher.md` captures the design for managing MCP servers as first-class lifecycle-aware catalog resources (deploy/redeploy/undeploy/status/restart/discover via lifecycle agent playbooks) AND a friendly playbook launcher in the GUI (workload form generation from YAML + inline result panel). Five phases: noetl primitives → gateway shim → ops templates → GUI run dialog + Mcp tab → docs + e2e. Phase 1 scoped for `noetl/noetl` v2.25.x; Phase 4 for `noetl/gui` v1.2.x.
- **GUI v1.2.0 deployed to kind** (April 28, 2026): theme PR #14 merged → semantic-release auto-bumped to v1.2.0 → ai-meta `repos/gui` gitlink bumped to `b2e6586` via `65a130d`; helm release `noetl-gui` revision 3 running `ghcr.io/noetl/gui:v1.2.0`.
- **Agent noop-end discards result bug** (April 28, 2026): `automation/agents/kubernetes/runtime` v1's `end` step is `kind: noop`, so `playbook.completed.result.context = {step: "end", status: "noop"}` and the GUI terminal renders nothing for `mcp/kubernetes` commands like `pods`. Mitigation in `repos/ops` branch `kadyapam/runtime-agent-return-summary` at `5468f2f` → merged as `noetl/ops#13`; agent re-registered as catalog v2; ai-meta `repos/ops` gitlink bumped via `7fb8cdf`. Engine-side fix tracked in `sync/issues/2026-04-28-bug-agent-noop-end-step-discards-result.md`.
- **Phase 1 MCP catalog work merged as v2.25.0** (April 28, 2026): `noetl/noetl#392` merged; semantic-release auto-bumped to `v2.25.0`. Adds `noetl.server.api.mcp` with three new endpoints (`POST /api/mcp/{path}/lifecycle/{verb}`, `POST /api/mcp/{path}/discover`, `GET /api/catalog/{path}/ui_schema`) plus workload-form inference. Resource model unchanged. Cleanup follow-up at `noetl/noetl#393` (branch `kadyapam/mcp-followup-pass-2-fixes`) addresses the eight Copilot pass-2 findings: cache-mutation (shallow-copy payload), error mapping (503 not 404 for IO errors), workload_overrides reserved-keys check, async DNS via `loop.getaddrinfo`, unused imports, stale docstring, multi-directive `finditer` parser, 2+ space indent regex.
- **Phase 4 GUI run dialog PR open** (April 28, 2026): `noetl/gui#16` (branch `kadyapam/playbook-run-dialog` at `e3f213f`) adds a `Run` button per catalog row that opens `PlaybookRunDialog` — fetches `/api/catalog/{path}/ui_schema`, renders metadata.description as markdown, generates one antd input per workload field by inferred kind, polls `/api/executions/{id}` every 2 s and renders the agent's text via the existing terminal fallback chain. Existing JSON Payload modal stays as power-user fallback.
- **E2E fixture split landed** (April 2026): dedicated `noetl/e2e` repo now owns integration-test fixtures and docs; credential JSON templates may be committed, but local credential JSON values must remain uncommitted.
- **Execution observability typed and released** (April 26, 2026): `repos/noetl` release `v2.23.2` includes typed execution list/detail responses, AI explain fixes, and API review fixes. Remember `noetl.execution` is a projection; `noetl.command` + `noetl.event` are source-of-truth execution state tables together with the projection.
- **GUI terminal workspace shipped** (April 26, 2026): `repos/gui` release `v1.0.7` contains the terminal-first workspace, old Mac style theme, header/footer menus, runtime `/env-config.js` injection, direct/gateway API modes, resizable and maximizable terminal/dashboard panes, improved AI explain rendering, and Kubernetes MCP terminal commands.
- **Local kind GUI + MCP deploy baseline** (April 26, 2026): deployed `ghcr.io/noetl/gui:v1.0.7` to namespace `gui` using `repos/ops/automation/development/gui.yaml` with `action=deploy`, `image_pull_policy=Always`, `api_mode=direct`, `api_base_url=http://722-2.local:8082`, and `mcp_kubernetes_url=/mcp/kubernetes`; deployed `quay.io/containers/kubernetes_mcp_server:v0.0.61` to namespace `mcp` using `repos/ops/automation/development/mcp_kubernetes.yaml`.
- **Kubernetes MCP terminal verified** (April 26, 2026): browser validation at `http://localhost:38081/catalog` confirmed `mcp status` reports `kubernetes :: healthy url=/mcp/kubernetes tools=13`, `k8s namespaces` lists local kind namespaces, and `k8s pods mcp` returns the `kubernetes-mcp-server` pod `1/1 Running`.
- **MCP-as-agent-playbook architecture implemented in draft PRs** (April 26, 2026): MCP access is now designed to run through NoETL agent playbooks, not direct GUI/browser calls. Draft PRs opened: `noetl/noetl#386` adds `tool.kind: mcp`, executable `agent` catalog resources, and `mcp`/`memory` resource kinds; `noetl/ops#11` adds `automation/agents/kubernetes/runtime`; `noetl/gui#11` routes terminal `mcp`/`k8s` commands through the agent execution; `noetl/gateway#8` refreshes the gateway execution contract and GraphQL `resourceKind`; `noetl/docs#12` documents catalog resources and MCP agent execution. Local kind validation registered the Kubernetes runtime agent as `resource_type=agent` and completed executions `614016805878628425` (`tools/list`) and `614016931808411774` (`pods_list_in_namespace`).
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

- Track PFT execution `614768929377878676` to terminal state and run `monitor_pft_execution.ipynb` for GO/NO-GO; on GO, capture per-facility validation_log counts and confirm assessments→conditions→medications→vital_signs→demographics all hit 1000/1000.
- Resolve the `test_mds_batch_worker` post-`loop.done` render-scope bug (execution `614782701987430447`): apply the fixture-level `{{ workload.* }}` mitigation in `repos/e2e/fixtures/playbooks/pft_flow_test/test_mds_batch_worker.yaml` to unblock PFT, then open a `noetl/noetl` issue + PR to fix the input renderer scope for `loop.done`-arc destinations and add a regression test under `tests/integration/dsl/v2/`.
- Track Copilot pass-3 review on `noetl/noetl#393`; merge once green. Then trigger `BumpAndDeployV3` (or its successor) to roll v2.25.1 onto kind so the lifecycle/discover/ui_schema endpoints are live with the cleanup fixes.
- Track Copilot review on `noetl/gui#16`; merge once green. Then redeploy gui (likely v1.3.0 since `feat:` triggers a minor bump) so the friendly playbook run dialog is visible.
- After both PRs are merged, bump ai-meta gitlinks for `repos/noetl` and `repos/gui` in a single `chore(sync)` commit.
- Open the remaining architecture issues — Phase 2 (gateway shim with route-aware `check_playbook_access` for `/api/mcp/...`) and Phase 3 (ops lifecycle agent templates + curated `Mcp` registration playbook) — mirroring `sync/issues/2026-04-28-architecture-mcp-catalog-and-friendly-playbook-launcher.md`.
- Review + merge `noetl/noetl#392` after wiring admin-role auth on the lifecycle endpoints, adding a kind smoke test, and writing the `Mcp` resource model docs in `repos/docs`. Then start Phase 2 (gateway shim + GraphQL `Mcp.lifecycle` field) and Phase 3 (ops templates: split runtime vs. lifecycle agents under `automation/agents/kubernetes/`, register `Mcp` resource via refactored `automation/development/mcp_kubernetes.yaml`).
- Track execution `615068195786850757` to terminal state. If it hits the same empty-error `command.failed` cluster on `run_mds_batch_workers` around facility 4 like the previous run, scale `noetl-worker` past 3 replicas first (current `max_in_flight=5` × 3 children expects ≥48 worker capacity per the playbook comment; we currently have 3).
- Investigate the empty-error `command.failed` cluster on `run_mds_batch_workers` under low worker capacity (parent execution `614955937991754550` failed at facility 4): 3 workers ready / 208 offline in `/api/worker/pools` is well under the flow's assumed `3 × 16 = 48` capacity. Reap zombie workers, scale up, then rerun on the patched sub-playbook v7.
- File two follow-up `noetl/noetl` issues separately from the `loop.done` render-scope one: (a) sub-execution top-level status not transitioning to COMPLETED after `end` step finishes when parent advances via `call.done`; (b) empty-error `command.failed` cluster on `run_mds_batch_workers` under low worker capacity (likely lease/timeout drop without enriched error context).
- Merge `repos/docs` branch `kadyapam/catalog-discovered-mcp-terminal-docs` upstream, then bump ai-meta gitlink for `repos/docs` from `88580e8` to the merged tip (currently 10 commits ahead of `origin/main` `519e707`).
- After PFT completes successfully, draft the `chore(release): version 2.24.3` cut for `repos/noetl` if the schema-reapply + observability fixes warrant a new tagged release.
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
