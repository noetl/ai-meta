# Sync Note: 2026-05-26 — inline-detector catalog HTTP fallback `version="latest"` 404

## Summary
- The inline-execution detector's catalog HTTP fallback (introduced in noetl #610) was sending `{"path": ..., "version": "latest"}` to `/api/catalog/resource`. The server cannot parse the string `"latest"` — it returns 404, and the detector falls through to a filesystem placeholder stub. Every step in the stub trips `missing_tool_kind`, so the decision is always `inline=False`.
- Surfaced during Phase D live validation of Round B (noetl #612). Smoke playbook ran clean but child execution lifecycle showed full dispatched path (`command.claimed`, `command.issued`) with zero `meta.inlined_in_parent` markers, proving the Round B runner never fired.
- Fix omits the `version` field. Server treats a missing field as "give me the highest version row" for the path.

## Scope (Repos)
- repos/noetl: `noetl/tools/agent/executor.py` line 864 — request body changes from `{"path": entrypoint, "version": "latest"}` to `{"path": entrypoint}`. Header comment explains the bug, the GKE reproduction, and the forward-compat rationale for omitting the field rather than sending `null`.
- repos/noetl: `tests/tools/test_agent_executor.py` — updated assertion on `test_load_inline_child_from_catalog_returns_payload_dict`; added regression test `test_load_inline_child_from_catalog_omits_version_field` that asserts `"version" not in body`.

## PRs / Links
- noetl: https://github.com/noetl/noetl/pull/613 (draft, fix branch `kadyapam/inline-detector-catalog-version-fix`)

## Resulting SHAs / Tags
- repos/noetl: branch `kadyapam/inline-detector-catalog-version-fix` at `435a0207` (from `main` at `009a7f72`, v2.102.0).
- repos/noetl-wiki: no change. The catalog fallback is an internal implementation detail and the operator-facing contract (modes + decision shape) is unchanged.

## Compatibility / Notes
- Backward compatible: yes.
- Migration required: no.
- Config/DSL impact: none. `NOETL_INLINE_TRIVIAL_CHILDREN` semantics unchanged. Detector public surface unchanged. Inline runner public surface unchanged.
- Known risks: low. Only deployment where the bug was visible is one whose child playbook lives in the server-side catalog (i.e. every cluster deploy). Pre-fix, those deployments always returned `inline=False` due to the 404. Post-fix, decisions evaluate against real playbook content. Under `dry_run` this only changes `meta.inline_decision` content. Under `enforce`, this is the point at which the Round B runner will actually fire for eligible children — Round B has 74 passing tests including dispatched-vs-inline event-sequence parity.

## Follow-ups
- [x] Merge PR #613. (merged as `c0fb3b8d`)
- [x] Bump `repos/noetl` pointer in ai-meta after merge. (`310accc8` = v2.102.1)
- [x] Rebuild image off the new `main` (`inline-runner-v2-20260526070157`), redeploy GKE (helm rev 167), flip worker env to `NOETL_INLINE_TRIVIAL_CHILDREN=enforce`.
- [x] Re-run smoke playbook `tests/inline_runner_phase_d_smoke` — detector returns `inline=True`; runner fires; surfaced Bugs A, B, C (see below).
- [x] PR #614 (Bug A — uuid4 modulus → bigint-safe child id) merged as `4d4c990e`; v2.102.2 published.
- [x] PR #615 (Bug B — terminal result envelope semantics) merged as `105f9242`; v2.102.3 published.
- [x] PR #616 (Bug C — cancellation probe endpoint) merged as `f2e18911`; v2.102.4 published.
- [x] Phase D success path: 5 vertex-ai-stub turns under 1s, warm steady-state ~0.75s (~5x speedup vs Round A).
- [x] Phase D parent-cancel spot-check: `PLAYBOOK_CANCELLED` envelope on parent's call.done; `execution.cancelled` event present; child id 18 digits.
- [x] Wiki seam doc on `repos/noetl-wiki` `inline_runner.md` — covers id allocation (uuid4 % 10**18 bigint constraint) + cancellation-check endpoint cross-reference + Phase D outcome.
- [x] Handoff thread `2026-05-26-noetl-inline-trivial-children` moved to `handoffs/archive/`.

## Phase D — final outcome
- Round B inline runner is production-verified on GKE.
- Cluster left on helm rev 170, image `inline-runner-v5-20260526090617` (v2.102.4), `NOETL_INLINE_TRIVIAL_CHILDREN=enforce`.
- Smoke playbooks (`tests/inline_runner_phase_d_smoke`, `tests/inline_cancel_smoke_parent`, `automation/agents/mcp/vertex-ai-stub`, `automation/agents/mcp/inline-cancel-smoke`) remain in GKE catalog as durable Phase D fixtures for future re-verification.

## Phase D — defects found, follow-up PR open
- Phase D ran twice. First attempt was inadvertently against `localhost:8082` which routes to the `kind-noetl` cluster (not the GKE target), explaining why the runner appeared not to fire — that cluster is on an old image without Round B code. Second attempt port-forwarded directly to the GKE noetl service (`kubectl ... port-forward svc/noetl 18082:8082`) and registered the smoke playbook + `automation/agents/mcp/vertex-ai-stub` child into the GKE catalog.
- **Bug A (confirmed)**: `_allocate_child_execution_id` returned `uuid4().int % (10 ** 20)` — 20-digit ids up to ~9.99e19. PostgreSQL `bigint` max is ~9.22e18. Live overflow string: `value "69474466565741823165" is out of range for type bigint`. Child event stream became unretrievable; some events leaked into the parent's stream.
- **Bug B (confirmed independent after PR #614 merged + re-run)**: parent's `call.done.result.context.data` was `{"status": "ok"}` instead of `vertex-ai-stub`'s canned diagnosis payload. Worker logs showed the Python step DID execute (`[RESULT] Step canned_chat_completion: inline result (1799b)`) followed by `[RESULT] Step end: inline result (15b)`. The runner's `last_result` was being overwritten by the noop `end` step's sentinel — diverged from the dispatched path's `_fetch_sub_execution_terminal_result` which filters boundary node names (`start`, `end`, `""`, `None`).
- **PR #614 merged** as `4d4c990e`; release CI bumped v2.102.2 (`a0a6f605`); ai-meta pointer bumped to `a0a6f605`.
- **PR #615 merged** as `105f9242`; release CI bumped v2.102.3 (`5b41e323`); ai-meta pointer bumped. Phase D re-run on helm rev 169 / image `inline-runner-v4-20260526084305`:
  - 5 smoke turns through `automation/agents/mcp/vertex-ai-stub` all under 1s (warm steady-state ~0.75s vs Round A warm ~4s = ~5x speedup).
  - Parent's `call.done.result.context.data` now carries the full vertex-ai-stub canned diagnosis (`category`, `confidence`, `root_cause`, `vertex-stub`, `gemini-2.0-flash` markers all present).
  - Keychain redaction preserved by the runner's `ResultHandler` scrub (`[REDACTED]` on `_meta.usage.{total,prompt,completion}_tokens`).
- **Bug C surfaced during parent-cancel cascade spot-check** — exec `635384123825062053` issued cancel at t=1.5s. `noetl cancel` succeeded; `execution.cancelled` event landed in parent log; `/api/executions/<id>/cancellation-check` returns `{"cancelled": true}`. But the inline runner ran ALL THREE child steps to completion (6 seconds of sleeps after the cancel). Root cause: `_make_cancellation_probe` hits `/api/executions/{id}/status` instead of `/api/executions/{id}/cancellation-check`. The `/status` endpoint has no `status` field, so the probe's `doc.get("status") == "cancelled"` always returned False.
- **PR #616 in flight** (https://github.com/noetl/noetl/pull/616): probe URL changes to `/cancellation-check`; result parsing changes to `bool(doc.get("cancelled"))`. 7 new regression tests; 63/63 tests pass.

## Memory Entries
- `memory/inbox/2026/05/20260526-135135-round-b-phase-d-found-pre-existing-catalog-version-latest-bu.md` (Phase D findings + worker env reverted to dry_run).
- `memory/inbox/2026/05/20260526-125926-inline-execution-round-b-merged-pr-612-lands-worker-inline-r.md` (Round B merge + pointer bump on v2.102.0).
- `memory/compactions/20260526-063333.md` (Round A arc consolidation, including PR #610 that introduced the catalog fallback).

## Verification
- Tests run: `uv run pytest tests/tools/test_agent_executor.py -q` → 40 passed.
- Environments verified: bug reproduction confirmed live on GKE Option A (helm rev 166, image `inline-runner-20260526062449`, project `noetl-demo-19700101`). Worker env reverted from `enforce` to `dry_run` as a safety measure pending merge.
- Observability notes: smoke playbook `tests/inline_runner_phase_d_smoke` registered in catalog (catalog_id `635314729543533052`). Execution `635314756663902717` (parent) + `635314763886494217` (child) capture the placeholder-cascade signature for future grep.
