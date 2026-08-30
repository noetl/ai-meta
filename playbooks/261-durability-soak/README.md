# Soak design — measuring the D1 durability window

For [ehdb#261](https://github.com/noetl/ehdb/issues/261), now that
[ehdb#328](https://github.com/noetl/ehdb/issues/328) makes the window
measurable at all. Produces the number
[`durability-window.md`](https://github.com/noetl/ehdb/blob/main/docs/spec/durability-window.md)
§7 puts on the primary-serve gate.

> Read-only against prod. The load itself runs in **kind**, not prod.

## ⚠⚠ The one design decision that determines whether this works

**The soak must include a deliberately quiet shard.**

Sealing is triggered by size (8 MiB) or record count (1024) and — until
[ehdb#329](https://github.com/noetl/ehdb/issues/329) is enabled — **never by
age**. So a shard under sustained load seals constantly and shows a window of
seconds, while an idle shard's window grows without bound.

A uniform saturating soak therefore **cannot detect the defect it is being run to
measure.** It would report an excellent p99 and confirm health that is not there.

This is the same shape as an earlier finding on this platform: *a saturating
burst measures the pool, not the bus.* The load shape decides the answer more
than the rate does.

## ✅ It is runnable — and it has been run

```bash
# BEFORE: today's prod behaviour (no age trigger)
cargo run -p ehdb-l0 --example durability_soak -- --seconds 30

# AFTER: what ehdb#329 would enable
cargo run -p ehdb-l0 --example durability_soak -- --seconds 30 --seal-max-age-ms 5000
```

Entirely in-process — temp dirs and a `LocalFsSubstrate`. **No cluster, no
prod.** Landed as [ehdb#340](https://github.com/noetl/ehdb/pull/340).

### Measured, 20 s, four shards

| arm | age trigger OFF | `seal_max_age = 5 s` |
| :-- | --: | --: |
| A saturating | 5.5 s | 4.8 s |
| **B quiet** | **20.0 s** (whole run, unbounded) | **5.0 s** |
| **C trickle** | **20.0 s** | **5.1 s** |
| D bursty | 20.0 s | 5.1 s |
| seals | 4 | 10 |

The age trigger bounds every arm, and the part-count cost is **measured**: 4 → 10
seals.

### ⚠⚠ The number that settles the metric question

Same instant, same engine:

```
mean append→durable            4.869 s   ← the real window
seal-relative upload_lag mean  0.042 s   ← what upload_lag_micros_total reports
```

**116× apart.** `upload_lag` starts at the seal and is structurally blind to the
term that dominates on a quiet shard. That is not a calibration difference; it is
a different quantity.

---

## Arms

Run all four concurrently, on one writer, on distinct shards:

| arm | shape | what it measures |
| :-- | :-- | :-- |
| **A — saturating** | continuous append at target rate | the window under load; seal-triggered path |
| **B — quiet** | **3 records, then nothing for the whole soak** | ⚠ the unbounded window. This arm is the point. |
| **C — trickle** | 1 record every 30 s | the realistic worst case: never fills a part, never idle enough to notice |
| **D — bursty** | 2 min at rate, 10 min idle, repeat | whether a burst's tail is left stranded when load stops |

⚠ **Arm C is the one most likely to be missing from a soak someone else designs.**
It is neither busy nor idle, and it is the shape most production shards actually
have.

## What to record

From the F4 instrument, per shard, sampled every 15 s:

- `ehdb_l0_unreplicated_age_seconds` — **max**, not mean. The window is bounded
  by its maximum; a mean is consistent with a p99 two orders larger.
- `ehdb_l0_unreplicated_records`
- `ehdb_l0_replicated_lag_seconds` — p50 / p99 / max from the histogram.
- `ehdb_l0_durability_sample_ok` — ⚠ if this is ever 0, the samples around it are
  missing for a *stated* reason; do not average across the gap.

And for the cost side of [#329](https://github.com/noetl/ehdb/issues/329):

- part count per shard, before and after enabling `seal_max_age`.
- `seals` rate.

## ⚠ Readings that would be misleading

- **`upload_lag_micros_total` / `mean_upload_lag_micros`.** Measured from the
  **seal**. It cannot see the pre-seal term, which is the dominant one on arms
  B and C. Do not put it in the report; it will read healthy.
- **`ehdb_feed_shard_lag` / `ehdb_feed_total_lag`.** Consumer backlog, not
  replication lag. Adjacent name, unrelated meaning.
- **A p99 computed across all four arms pooled.** Arm A dominates the sample
  count and would bury arms B and C entirely. **Report per arm.**

## Expected result before #329 is enabled

- Arm A: window in seconds.
- Arm B: window grows monotonically for the whole soak, unbounded. **This is the
  pass condition for the soak, not a failure** — it is the finding reproduced
  under measurement.
- Arm C: sawtooth reaching minutes-to-hours depending on record size.
- Arm D: window grows through each idle stretch, collapses on the next burst.

⚠ If arm B does **not** grow, something is wrong with the *soak*, not with the
system: either the shard is receiving traffic it should not be, or the metric is
not wired. Check `ehdb_l0_durability_sample_ok` and
`ehdb_l0_unreplicated_records` before concluding anything about durability.
That check is the soak's own positive control.

## After #329 is enabled (G1b)

Re-run identically. Pass conditions:

- All four arms: `max(unreplicated_age) ≤ 2 × seal_max_age`.
- Arm B specifically bounded — the whole point of the change.
- Part count rise on arms B and C **measured and recorded**, not assumed
  acceptable.

## What this soak does not answer

- Whether the substrate is an independent failure domain. It is not, today
  ([ehdb#332](https://github.com/noetl/ehdb/issues/332)) — the copy shares the
  writer's PVC. A perfect window over a shared disk is still one disk.
- Anything about single-writer safety
  ([#330](https://github.com/noetl/ehdb/issues/330) /
  [#331](https://github.com/noetl/ehdb/issues/331)).

Those are separate gates; see [`../324-four-gates/README.md`](../324-four-gates/README.md).
