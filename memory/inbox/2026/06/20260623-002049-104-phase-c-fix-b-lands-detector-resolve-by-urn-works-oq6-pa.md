# #104 Phase C: fix B lands (detector), resolve-by-URN works; OQ6 parity gap (b) remains
- Timestamp: 2026-06-23T00:20:49Z
- Author: Kadyapam
- Tags: noetl,104,phase-c,resolve-by-urn,refs-in-state,oq6,parity,worker,fix-b

## Summary
Fix B committed worker 8379aeb on feat/104-phase-c-resolve-by-urn: path_satisfiable None-arm force-resolves on a bare _ref stub (analogous to _truncated carve-out); 37 unit tests green incl new bare_ref_stub_summary_forces_resolution, 6 existing detector tests unchanged (no #101/#115 regression). Re-ran 3-pass rig: DETECTOR BLOCKER GONE + resolve-by-URN PROVEN — PASS 1 passed=1, gcs put Δ4 + gcs get Δ2 (try_resolve feather-key-miss -> json-key-hit), bound full 1200 rows from GCS; off-server invariants intact every leg. TWO remaining reds: (a) RIG LABEL — result is JSON-tier (media_type application/json) so resolver returns resolved_json not resolved_feather; PASS1 asserts resolved_feather -> false-red; fix=assert resolved_feather+resolved_json>=1. (b) REAL OQ6 PARITY GAP — legacy resolve_ref (GET /api/result/resolve) returns the tool-envelope {data:{generate_rows:{columns,rows}}} (rows at data.generate_rows.rows) while resolve-by-URN/GCS returns flattened {columns,rows}; fixture binds start.rows -> works for GCS (PASS1) not legacy (PASS2 fallback + PASS3 parity both passed=0). Single-tool steps flatten inline (cf consume.bulk_resolved) so flattened is canonical -> legacy resolve_ref/splice_resolved reconstruction is the divergent one (pre-existing refs-in-state limitation, masked until fix B fired the detector). OQ6 byte-identical NOT met. DECISION: (B1) fix legacy resolve_ref->splice to reconstruct flattened single-tool shape, or (B2) normalize both resolve outputs pre-splice. NOT forced. PRs HELD (resolve-by-URN works but OQ6 parity unmet). #104 comment 4774353923. Phase C branches local: server 4bdf16a, worker 8379aeb, e2e 1d3fa79. Prod untouched, baseline restored.

## Actions
-

## Repos
-

## Related
-
