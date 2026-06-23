# #104 Phase C resolve-by-URN: validated red, blocked on refs-in-state bulk detector
- Timestamp: 2026-06-23T00:00:45Z
- Author: Kadyapam
- Tags: noetl,104,phase-c,resolve-by-urn,refs-in-state,worker,blocked,validation

## Summary
Phase C code (server GCS object backend + cell registry, worker result_resolver/result_locator) is committed on feat/104-phase-c-resolve-by-urn (server/worker/e2e, LOCAL not pushed). First end-to-end run of kind_validate_result_resolve.sh: all 3 passes passed=0 INCLUDING pass3 (legacy, resolve OFF) -> cause is UPSTREAM of Phase C. Write side proven (gcs put Δ4, /api/internal/cells 200, off-server invariants intact every leg: event_rows==distinct, catalog0=0, orch_event=0). ROOT CAUSE: over-budget producer externalizes as a bare _ref stub flat binding {_ref,data:{_ref}}; consume binds {{start.rows[1100][0]}} but step_needs_bulk_resolution->path_satisfiable None-arm (command.rs ~1845: 'None => return !o.contains_key(_truncated)') assumes summarise_value keeps every key, so absent 'rows' in the stub => 'absent in full payload' => no resolve. Resolve branch (legacy AND Phase C resolve_by_urn) is gated behind this, never reached -> bind_bulk gets None -> TypeError. Pre-existing refs-in-state (#115 P1/#101) consume defect, surfaced by Phase C fixture. Precedent for fix is the _truncated carve-out one line up. DECISION NEEDED: (A) make flat binding carry the key-preserving summary, or (B) force-resolve when summary is a bare ref-stub (minimal, safe, analogous to _truncated) — not patched unilaterally because it shifts selective-resolution behavior #101/#115 tuned. Rig metric-guard fix landed e2e@1d3fa79 (set -e abort on absent baseline counter). #104 comment 4774239508. NEXT: pick A/B, land worker fix, re-run rig, then open Phase C PRs.

## Actions
-

## Repos
-

## Related
-
