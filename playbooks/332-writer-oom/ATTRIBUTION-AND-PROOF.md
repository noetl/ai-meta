# Reconnect-burst allocation: measured attribution, and the fix proven in prod

**2026-09-21.** Measurement first, then the fix, then the burst proof — in that
order, and the measurement **overturned two of my own earlier conclusions**.

## 1. The measured attribution

Instrument: `VmRSS` from `/proc/1/status` **inside the container**, sampled at
200 ms. ⚠ Not `kubectl top` — that samples every ~15 s and can return a metric
from a container that has **already died**, which is exactly how a 12 GiB OOM
read as "2947 Mi, healthy" yesterday.

### Controlled arms in kind (181 MB tier store, 20 clients each)

| path | delta RSS |
| :-- | --: |
| tier appends (face 9110), 200 appends × 20 clients | **+11 MB** |
| claim face 9101, 20 connections | +0 MB |
| group face 9104, 20 connections | +0 MB |
| events ingest 9103, 20 connections | +0 MB |
| tier reads, 1 and 6 concurrent | +0 MB |

**Correction #1.** My earlier explanation — "`max_inflight=4` still permits
4 × 2.9 GB of concurrent append clones" — is **wrong**. `store_lock` is an
exclusive per-tier `RwLock` and `append` takes `.write()`, so **tier appends are
serialised**: only one state clone can exist at a time. That arithmetic was
never possible.

### The dimension I had missed: record COUNT, not bytes

| store shape | on disk | RSS/store |
| :-- | --: | --: |
| 2500 **large** records (16 KB pad) | 157 MB | **0.69×** |
| 12000 **small** records (48 B pad) | 5.8 MB | **2.8×** |

Per-record overhead dominates for small records — a 4× swing in the ratio.

**This closes the contradiction.** Production's `eventlog.jsonl` was **1.08 GB
of small events**: `1.08 GB × 2.8 ≈ 3.0 GB`, which *is* the observed ~2.9 GB
baseline. My first kind rig used few large records, which is why its arms
measured +11 MB instead of GB-scale — the rig could not exhibit the failure.

**Correction #2.** The culprit *is* the tier path after all — but through the
record-count dimension, not through concurrent appends.

Cold-open shape, measured: peak **0.89×** on-disk, resident **0.69×** (for large
records). The load is visible as a staircase: `10 → 16 → 22 → … → 54 → 140 → 109`.

## 2. The fix, working in production

Both tiers have now sealed, by **rename**, with **nothing deleted**:

```
eventlog.jsonl.1     1,085,472,212 B   <- preserved
eventlog.jsonl             650,092 B   <- fresh active
projection.jsonl.1   3,301,113,835 B   <- preserved
projection.jsonl            49,581 B   <- fresh active
```

`EHDB tier store sealed … tier="eventlog" bytes=1085472212 sealed=…/eventlog.jsonl.1`

**RSS: 2.9 GB → 186 MB (94% reduction).** That is `forget_runtime` releasing the
replayed state — the seal bounding the *process*, not just the file.

## 3. The burst proof — PASSED

Driven on prod by rolling all three worker pools (the same event that OOM-killed
the writer at 8 GiB and again at 12 GiB), entered on a verified in-flight window
(10 started / 9 completed):

```
base 211 MB → PEAK 3173 MB (23:26:59) → final 139 MB
restarts=1 (unchanged — the 22:13 OOM, before the seal fired)
same container throughout (started 22:13:38, never restarted)
all workers reconnected, 0 claim-connect failures
```

Peak **3173 MB against a 12 GiB limit — survived with 74% headroom**, where the
identical burst previously exceeded 12 GiB from a 2.9 GB baseline.

The burst *does* still allocate ~3 GB transiently. What changed is the baseline
it starts from: removing 2.9 GB of resident state is what made the same spike
survivable. **Memory plateaus and returns** (139 MB) rather than climbing.

## 4. Projector shadow soak — coverage still 0%, NOT flip-ready

Projector confirmed **OFF**. 12-minute window:

| | value |
| :-- | --: |
| **denominator** — distinct executions | **12** |
| events persisted | 198 |
| projection-mirror attempts | **0** |
| cross-store parity samples | 77 |
| usable verdicts | **0** |

⚠ **The comparator failure is pre-existing, not a regression from sealing.**
Over a 100-minute window *spanning before and after the seal*, it reported
`tier reply carried no comparable records` **501 times** — identically on both
sides. And the data is intact: the sampled execution has **10 hits in
`eventlog.jsonl.1`**, the sealed segment.

So the soak still measures nothing, for the same pre-existing reason, and
"0 divergences" over ~0 attempts would be the vacuous pass. **Do not flip.**

## What remains

1. The **projection tier is 3.3 GB sealed but its active segment will grow
   again** — the seal now bounds it, but the 256 MiB threshold means a merged
   read spans more segments over time.
2. The **comparator relay returns no comparable records** — pre-existing, and it
   is the actual blocker for any meaningful projector soak.
3. The burst still allocates ~3 GB transiently; that is now survivable but not
   explained. It was not attributable to any tier face in the kind arms.
