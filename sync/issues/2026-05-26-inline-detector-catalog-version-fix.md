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
- [ ] Merge PR #613.
- [ ] Bump `repos/noetl` pointer in ai-meta after merge.
- [ ] Rebuild image off the new `main`, redeploy GKE, flip worker env back to `NOETL_INLINE_TRIVIAL_CHILDREN=enforce`.
- [ ] Re-run smoke playbook `tests/inline_runner_phase_d_smoke` — confirm `meta.inlined_in_parent` + `meta.inline_mode = "worker"` keys appear on child events.
- [ ] Spot-check parent-cancel cascade with an inline child in flight (Phase D step 15 of `round-03-prompt.md`).
- [ ] Then close the `2026-05-26-noetl-inline-trivial-children` handoff thread by moving it to `handoffs/archive/` and writing the final round-04 result.
- [ ] Then document the uuid4-derived child `execution_id` seam on `inline_runner.md` (deferred from the Round B merge close-out).

## Memory Entries
- `memory/inbox/2026/05/20260526-135135-round-b-phase-d-found-pre-existing-catalog-version-latest-bu.md` (Phase D findings + worker env reverted to dry_run).
- `memory/inbox/2026/05/20260526-125926-inline-execution-round-b-merged-pr-612-lands-worker-inline-r.md` (Round B merge + pointer bump on v2.102.0).
- `memory/compactions/20260526-063333.md` (Round A arc consolidation, including PR #610 that introduced the catalog fallback).

## Verification
- Tests run: `uv run pytest tests/tools/test_agent_executor.py -q` → 40 passed.
- Environments verified: bug reproduction confirmed live on GKE Option A (helm rev 166, image `inline-runner-20260526062449`, project `noetl-demo-19700101`). Worker env reverted from `enforce` to `dry_run` as a safety measure pending merge.
- Observability notes: smoke playbook `tests/inline_runner_phase_d_smoke` registered in catalog (catalog_id `635314729543533052`). Execution `635314756663902717` (parent) + `635314763886494217` (child) capture the placeholder-cascade signature for future grep.
