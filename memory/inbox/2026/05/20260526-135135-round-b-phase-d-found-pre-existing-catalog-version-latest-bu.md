# Round B Phase D found pre-existing catalog version=latest bug — runner never fires on GKE
- Timestamp: 2026-05-26T13:51:35Z
- Author: Kadyapam
- Tags: noetl,inline-execution,round-b,phase-d,bug,pr-612,gke,catalog-fallback

## Summary
Phase D live validation of Round B inline runner on GKE surfaced a real defect in PR #610's catalog HTTP fallback: it sends version="latest" as a string, but /api/catalog/resource expects integer or null. Result: detector returns inline=False on every child due to placeholder cascade (catalog 404 → filesystem placeholder → missing_tool_kind reasons). Enforce mode safely falls back to dispatch (no production risk; safety net works), but Round B runner is never invoked. Defect pre-dates Round B — Round A 'live verified' meant event-log visibility, not decision correctness. Smoke playbook tests/inline_runner_phase_d_smoke registered + execution 635314756663902717 confirms: child execution 635314763886494217 went through full dispatched lifecycle, zero meta.inlined_in_parent markers. Worker env reverted from enforce to dry_run on revision 166. Helm rev 166, image inline-runner-20260526062449 (built from 009a7f72 = v2.102.0 PyPI). Spawned follow-up task to fix _load_inline_child_playbook_from_catalog line 864 — omit the version field so endpoint returns highest. Round B runner code itself is correct; the gate that should let it run is silently failing.

## Actions
-

## Repos
-

## Related
-
