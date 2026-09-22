
---

## ✅ Stage 1 — KIND PROOF PASSED on merged `main` (2026-09-21)

**Converged with a concurrent session rather than competing.** While I was
proving a narrower variant, another session reached the **same root cause
independently** and pushed to `noetl/server`, then merged it as
[#459](https://github.com/noetl/server/pull/459) (`53c6d6ef`), released in
**v3.112.4 / v3.112.5**.

Their fix is a superset of mine and I dropped mine (`76613d91`, never pushed):

| | mine | theirs (merged) |
| :-- | :-- | :-- |
| spine-rung hydration | in `materialize_from_wal` | in `events_for_recovery_or_postgres` |
| `fold` vs `fold_with_body` `normalise_null_json` gap | found, not fixed | **fixed** |
| guards | 3 | 4, incl. a positive control that hydration is load-bearing, plus idempotence |
| kind proof on a built image | yes | **no — they flagged this as the open step** |

Both of us left `events_for_recovery` itself untouched, so #332's comparator
ground truth is intact either way.

### The proof they were missing — merged `main`, built and deployed to kind

Fresh pod, both projector flags ON, 3 × `muno/probe/big-parent` + 2 ×
`test/simple_loop`, **all COMPLETED**:

| counter | value |
| :-- | --: |
| `projection_refold_total{verdict="digest_mismatch"}` | **0** |
| `projection_serve_refusal_total{reason="digest_mismatch"}` | **0** |
| `projection_refold_total{verdict="match"}` | 49 |
| `projection_refold_total{verdict="stored_behind_spine"}` | **21** |
| `projection_read_total{outcome="stale_within_window"}` | **21** |
| `crossstore_divergence{*}` (every kind) | 0 |
| `snapshot_gate{written}` / `{skipped_projector_owns}` | 0 / 31 |

⭐ **The zero is EXERCISED, not vacuous.** `stored_behind_spine` = 21 and
`stale_within_window` = 21 means `grant_for_behind` ran the full bounded Postgres
fold **21 times and agreed every time**. A zero with `stored_behind_spine` = 0
would have proved only that the check never ran — which is exactly how this
counter read 0 in prod before the projector was ever enabled.

Mechanism confirmed directly in the tier: every record now FULL —
`postgres` 1, `server` 6, `wal_spine` 5, **BARE 0**. Before the fix the same
query returned `wal_spine` BARE interleaved with `server` FULL at the same
`applied_count`.

Merged `main` test suite: **1133 passed**.

### Where prod stands — the flip is NOT done

The server fix **is deployed to prod** (digest moved
`sha256:73487c92…` → `sha256:78f017e3…`, deployed by `shastaratech@gmail.com`
2026-09-21). All four workloads healthy.

🛑 **But `NOETL_PROJECTOR_ENABLED` and `NOETL_PROJECTOR_OWNS_SNAPSHOT` are unset
on every prod workload.** Stage 1's actual acceptance step — enable both flags
together, canaried — has not been taken. `NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND=true`
IS already set on the prod server, so `grant_for_behind` is armed and will
execute as soon as snapshots start lagging.

⚠ Remember the pairing rule the earlier rollback established: the two flags must
move **together**. `PROJECTOR_ENABLED` alone gives two writers contending;
`OWNS_SNAPSHOT` alone (projector off) means **nobody** writes the snapshot —
`skipped_projector_owns` climbs while `projection_advanced_total` freezes.

⚠ A `noetl-state-builder-watchdog` service account also patches
`noetl-worker-system-pool` in prod. Any flag change there has a second actor.
