
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

### 🛑 The prod flip was NOT taken — and here is exactly why

Prod is quiet (no deploys for 3h) and carries the fix, so I opened the canary.
**The baseline stopped it.** Prod server v3.112.5, projector OFF, counters since
the pod's last restart (~19h):

```
projection_refold_total{verdict="digest_mismatch"}        0
projection_serve_refusal_total{reason="digest_mismatch"}  1   ← not zero
projection_refold_total{verdict="stored_behind_spine"}   10
projection_refold_total{verdict="match"}                  1
projection_read_total{outcome="stale_within_window"}      9
crossstore_divergence{kind="checksum",tier="projection"}  0
snapshot_gate{written}                                   56   (orchestrator self-writing, correct with projector off)
projection_advanced_total                                 0   (projector not running, correct)
```

**1 refusal in 10 bounded comparisons**, where kind proved 0 in 21. The owner's
bar is 0 and the gate was "explained AND zero". It is neither, so I did not flip.

⚠ **I could not tell whether it recurs, and I will not guess.** Six one-minute
samples were completely FLAT — `stored_behind_spine` stuck at 10 and
`snapshot_gate{written}` stuck at 56 — i.e. **prod had no traffic at all during
the window, so the sample has no denominator and tests nothing.** Reporting "it
did not recur" off that would be the same vacuous-zero error this document
already records twice.

**Leading hypothesis, untested:** the refusal is a *legacy* record — a snapshot
written by the PRE-fix server, still in the tier, verified after the roll. That
would explain kind (fresh pod, fresh executions) reading 0 while prod reads 1,
and it would age out. It is plausible and unverified.

### ⚠⚠ Prod has NO on-path instrument — close this before flipping

The serve-path diagnostic that located the whole defect was in my dropped commit
and is **not** in `main`. The merged fix ships an *offline* harness
(`harness_serve_path_digest_diff`), which is excellent for replaying captured
data but cannot observe a live prod refusal.

So today, if the projector were enabled and `digest_mismatch` moved, prod would
report a number and no reason — and the endpoint an operator would reach for
(`/api/ehdb/projection-fold/diff/{id}`) folds tier EVENTS, not the SNAPSHOT, and
**reports agreement on exactly the executions the serve path rejects**.

**Recommended order before any prod flip:**

1. Land the serve-path diagnostic on `main` (logs stored vs bounded version and
   digest plus the real diff paths; fires only on disagreement, so a healthy
   execution pays nothing). It is small and it is the only live instrument.
2. Wait for organic prod traffic and re-read with a real denominator, or replay
   the refusing execution through the offline harness to classify that 1.
3. Only then flip, **both flags together** — never one alone.

**Prod is untouched by this session. Reads only.** All five workloads ready,
`NOETL_PROJECTOR_ENABLED` and `NOETL_PROJECTOR_OWNS_SNAPSHOT` unset everywhere.
