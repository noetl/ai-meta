# The index fix, measured — and the correction it forced

## ⚠ v6.1.4 must not be deployed

`v6.1.4` (worker#336, merge `88c95d38`) ships the index build that **replays**
each segment through a `LocalReferenceEventLogDriver`. Replay holds the whole
segment in the reference-runtime cache. `backfill_segment_indexes` also spawned
one build per segment with **no concurrency bound**, and production has two
unindexed sealed segments — **1.08 GB and 3.3 GB**.

`v6.1.5` (worker#337) replaces it with a streaming build and serialises the
backfill.

## Measured: replay vs streaming, on data written by the real append path

1.05 GiB single sealed segment, 4,216 records, appended through the tier
service. Same pod, same emptyDir, same store — the arms differ only by the
container image (`image` is mutable on a pod and emptyDir survives a container
restart, so neither arm rebuilt the fixture).

| arm | peak RSS | build time | index |
| :-- | --: | --: | --: |
| RED — replay (v6.1.4) | **889 MiB** | 6 s | 4 ids |
| GREEN — streaming (v6.1.5) | **19 MiB** | 2 s | 4 ids |

Identical index content, **47× less memory**. The gate asserts the index is
non-empty and that both arms agree, because a build that indexed *nothing* would
also use little memory.

At production record count — a 973 MiB segment of **83,000 records**, matching
prod's 82,906 within 0.1% — the streaming build peaked at **17 MiB** and
finished in ~0.3–0.6 s. Peak RSS did not move between a 4,216-record segment and
an 83,000-record one, nor between one segment and four: **it is independent of
both segment size and segment count.**

## ⚠ Correction: my "~12 GB startup peak" was an overestimate

I predicted prod's replay-based backfill would peak near 12 GB by applying the
**2.8x** multiplier measured earlier for *small* events. That multiplier tracks
record **count**, and prod's sealed segment is 13 KB/record, not small. Measured
here, replay peaked at ~0.85x segment bytes.

So v6.1.4 was **not** facing a certain OOM against the 12 Gi limit. It was
facing an unbounded, unnecessary multi-GB allocation on every restart. The fix
is still right and still ships; the number I attached to it was not measured,
and I should not have stated it as though it were.

## The residual: what the index does NOT make fast

The index lets a read skip segments that **cannot** hold the execution. A
segment that **does** hold it is still opened and replayed in full. Measured on
real append-path data:

| store shape | read latency | vs the 2 s tier budget |
| :-- | --: | :-- |
| 1.05 GiB in **one** segment | **4.0 s** | over — times out |
| same data, **4 × 264 MiB** | **1.0 s** | under — succeeds |

So segment **size** drives read latency, and production's 256 MiB seal threshold
is the right size: reads land near 1 s.

⚠ **Production's legacy sealed segment is 1.08 GB — 4x the threshold** — because
it was the pre-existing active file at the first seal. The **969 executions
inside it** will stay over the 2 s budget even after this fix. The 32 in the
active segment, and everything appended from now on, will not.

This bounds what the fix can deliver and it must be reflected in the soak's
coverage denominator rather than discovered in it.

**Recommended, owner-gated, NOT done:** split that one legacy segment into
threshold-sized pieces by line. It is byte-preserving (no deletion, no
rewriting of record content) and in kind it moved exactly this read from 4.0 s
to 1.0 s. It still rewrites the durable mirror of an append-only log, so it is
the owner's call, not mine.

## ⚠ Three fixture bugs, each of which produced a confident wrong reading

Building a synthetic prod-shaped segment found three undocumented constraints of
the stored format, and each one first showed up as a *plausible result*:

1. **`--pad 65536` produced 262 KB lines**, so a "1.1 GB prod-shaped" store held
   4,216 records instead of 82,906. Replay cost tracks record count, so the
   fixture understated it — and the negative control caught it: reads with and
   without the index came back 1.02 s vs 1.01 s, no difference at all.
2. **Sequences must start at 1 and be contiguous.** My blocks started at 4151;
   the replay arm failed with `expected transaction sequence 1, got 4151` and
   the gate scored `ids=0` — correctly refusing to call it a comparison.
3. **`transaction_id` must be unique.** Duplicated across blocks, the driver
   deduped and only block 1 was visible, so reads returned "not found" in
   0.16 s — which reads exactly like a fast successful skip.

A fourth, from the surrounding run: probing `exec-9/17/21` returned 0.0 s and
looked like a perfect index skip. Those executions **did not exist**. A read of
an absent execution is fast for reasons that have nothing to do with the index.

I stopped bending the synthetic fixture after the third constraint. The
read-latency question is answered above on data written by the real append path,
which is better evidence than a synthetic file would have been.
