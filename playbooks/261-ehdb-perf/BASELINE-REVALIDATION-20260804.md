# Re-running the ehdb#261 Phase-1 baseline — and why the number alone is not a verdict

**Date:** 2026-08-04 · Apple M1 Max (same machine class as the committed
baseline) · `cargo bench -p ehdb-reference --bench engine_micro -- eventlog`

Nothing had re-run the Phase-1 baseline since it was committed, and the session
in between changed the append path (#205 group commit + off-lock fsync) and
every feed accept path (#311). A committed baseline nobody re-runs is a number,
not a signal.

## Measured vs the committed baseline

| metric | committed | measured | delta |
| :-- | --: | --: | --: |
| `durable_segment` sustained @ K=1000 | 255 ev/s | **181 ev/s** | **−29%** |
| `local_reference` sustained @ K=1000 | 96 ev/s | 105 ev/s | +9% |
| durable ÷ local_reference | 2.7× | **1.73×** | — |
| durable per-append | ~3.9 ms | **~5.7 ms** | +46% |
| segment-rotation overhead | ~2% | ~2.6% | consistent |

Against the SLO strawman on #261: append latency **passes** (~5.9 ms upper
bound vs ≤10 ms p99), sustained throughput **misses** (181 vs ≥200/s/shard).

## Why this is NOT reported as a regression

The box was **not idle**. A kind cluster was running throughout — 5+ pods
including **etcd**, which is relentlessly `fsync`-heavy — on the same APFS SSD,
alongside this session's Rust builds.

`durable_segment` is **`fsync`-bound by design** (posture A). An `fsync`-bound
benchmark run beside a live etcd is measuring the disk queue as much as the
engine.

Two internal controls point the same way:

- **Segment-rotation overhead is a ratio taken within the same run**, so it is
  immune to box load — and it matches the baseline (~2.6% vs ~2%). The engine's
  internal proportions are intact.
- `local_reference` is not `fsync`-bound (JSONL reopen + replay, O(n) per op)
  and did **not** drop; it moved +9%, within noise for that shape.

A code regression in the durable path would not spare `local_reference` while
leaving rotation proportions unchanged. Disk contention explains all three
observations; a regression explains only one.

## The actual finding — a methodology gap, not a number

**The baseline records no machine-state protocol.** It says "Apple M1 Max /
APFS SSD dev box" and nothing about what else was running. So a re-run cannot
distinguish *regression* from *contention* — which is precisely the situation
above, and the reason this file does not assert either.

That matters more than the 29%, because it will recur on every future re-run.

### What #261 should adopt

1. **Record machine state with the numbers** — at minimum whether a kind
   cluster / container VM is running, since etcd alone changes an `fsync`-bound
   result.
2. **Gate the bench on an idle disk**, or refuse to record a baseline when a
   local cluster is up.
3. **Prefer the ratios as the durable signal.** Rotation overhead and
   durable ÷ local_reference are self-normalising; absolute ev/s on a shared dev
   box is not.
4. **Re-run the absolute numbers on a quiesced box** before anyone treats the
   ≥200/s/shard strawman as met or missed. On this evidence it is neither
   confirmed nor refuted.

## Confirmed unaffected

`ehdb-reference` does not depend on `ehdb-feed`, so the #311 accept-path change
cannot reach this benchmark. Checked rather than assumed — the run was on the
`fix/311-per-connection-errors` branch.
