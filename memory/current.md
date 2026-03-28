# Current Memory

## Active Focus

- Maintain cross-repo orchestration quality and consistency.
- Keep submodule pointers aligned with merged upstream changes.
- Keep release/distribution workflows reproducible.
- Track and drive fixes for Jira bug set `AHM-4280..AHM-4284` mirrored to `noetl/noetl` issues `#261..#265`.
- Enforce NoETL release commit subject format without scope braces (`fix: ...`, not `fix(scope): ...`) so automation triggers.
- Keep GCP project context explicit: `noetl-demo-19700101` is operated under Adiona.org organization context.
- **DSL Refactoring in progress** (March 2026): Use the two canonical spec documents below as instructions when performing any NoETL DSL refactoring work.
- **DSL fixture migration execution started** (March 28, 2026): `repos/noetl/tests/fixtures/playbooks/pagination` migrated from legacy DSL fields (`args`, `outcome`, `set_ctx`, `set_iter`) toward target model (`input`, `output`, `set`) without touching Python source files.

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
- Continue DSL fixture migration beyond pagination into remaining `repos/noetl/tests/fixtures/playbooks/**` files, then run fixture validation against the current DSL runtime.

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
