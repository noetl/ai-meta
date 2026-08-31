# The tier holds 4.6% of the event log — and that is correct

**Resolved 2026-08-31. Not a defect. No fix required.**

## The alarming number, and why it was wrong

The EHDB event-log tier holds **47,060** records against Postgres's
**1,020,651** — 4.6%. That looked like catastrophic under-mirroring beneath
[#307](https://github.com/noetl/ai-meta/issues/307) and the whole primary-serve
direction.

It is an artefact of comparing a store against history that predates it.

## Measurement

Every `noetl.event` row from the archive dump, bucketed on its real `created_at`:

| window | events | share |
| :-- | --: | --: |
| before 2026-08-13 (pre-tier) | **975,542** | **95.6%** |
| 2026-08-13 → 08-31 (tier era) | **45,109** | 4.4% |

The tier holds **47,060**. Against the 45,109 authoritative events *in its own
window* that is **104%** — the tier has everything since it started, and ~4%
more.

## The four hypotheses, quantified

| hypothesis | share | evidence |
| :-- | --: | :-- |
| **Start date — mirroring enabled ~2026-08-13** | **~95.6%** | the tier's oldest record sits at the boundary, and Postgres volume is continuous across it (350–1,430/day either side). Nothing was removed |
| Retention / GC / rotation | **~0%** | GC leaves a ragged or size-driven tail. This is a clean date with ordinary volume on both sides |
| Structural under-mirroring (gated sink + 3 non-mirroring INSERT sites) | **~0% historically** | in-window the tier holds *more* than Postgres, not less |
| Selective-by-design | **0%** | with `MIRROR_SOURCE=server` the comparator's `mirror_expected` is true for every row |

## ⚠ The residual runs the other way

47,060 − 45,109 = **+1,951 (+4.3%)** surplus, consistent with the over-mirroring
tracked in [#313](https://github.com/noetl/ai-meta/issues/313) (11 duplicates +
4 orphans on a sampled execution). The live defect is **over**-mirroring, now
gated off by default via `NOETL_EHDB_SINK_MIRROR` (server#385, deployed
v3.99.2).

## Consequences

* **Equivalence is only measurable on post-2026-08-13 executions.** The sweep
  samples recently-completed work, so it is already in-window — but a sweep that
  reached further back would report pre-enablement executions as missing.
* **#307's serve-flip is not blocked by this.** The blocker is #313.
* The parked truncate is less consequential than it appeared: ~75% of the
  1.02M rows are two load-test days.

## Options — none implemented

1. **Do nothing.** Expected behaviour. *Recommended.*
2. **Record the enablement date** in the tier manifest so the comparator can
   scope itself. Small and additive, but it changes comparator behaviour on the
   parity path — an owner decision, not a slip-in.
3. **Backfill from the archive.** Expensive, and it would import the pre-#385
   over-mirroring into historical data. Not recommended.

## Method notes worth keeping

* ⚠ **Three magnitudes were reported wrong before this**, each by measuring a
  proxy rather than the source: "19 days" and "78 days" (both read off the
  **tier**), and "5,001,000 events" (a paginated count whose cursor never
  advanced — `next_cursor` was extracted as the *first* id on the page, so it
  re-read one window 5,001 times; the round number `5001 × 1000` was the tell).
* ⚠ A first attempt at this bucketing decoded snowflake ids and produced dates
  from **2024 to 2031**. Discarded in favour of the real `created_at` column.
  The broken version was plausible enough to support almost any narrative.
* The reliable number came from `pg_dump` output — the source — not from an API
  over a copy.
