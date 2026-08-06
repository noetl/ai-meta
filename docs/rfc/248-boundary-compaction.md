# RFC — compacting the ~1.7 GB of business payload already in `noetl.event`

**Decision needed from:** the user (architecture — this one changes an invariant)
**Related:** [ai-meta#248](https://github.com/noetl/ai-meta/issues/248),
[#195](https://github.com/noetl/ai-meta/issues/195)
**Status:** open, parked. Nothing attempted.

---

## 1. What is being asked

`NOETL_PERMANENT_LOG_LEAN` is **live in prod** (server v3.77.4, enabled
2026-08-05). It strips over-floor business payloads out of events **written from
now on** — `slimmed_total` and `slimmed_bytes_total` climb cleanly, with
`lean_stage_failed_total` at 0.

It does nothing for the **~1.7 GB already there**. Reclaiming that means
rewriting historical rows.

## 2. Why this is not a script

`noetl.event` is append-only **in practice, not merely by policy**. A search
across server and worker finds:

- **no `UPDATE noetl.event`**
- **no `DELETE FROM noetl.event`**

anywhere. The only writes are inserts. And the system's stated invariant is that
the log is immutable and replay is the source of truth.

So compaction is not an optimisation with a rollback; it mutates the one table
whose immutability everything else assumes. That is why it is filed as a
decision rather than a task.

## 3. The four questions a design has to answer

### Q1 — Is compaction permitted at all?

The honest first question, and it may be "no". If the event log is the audit
record, "we rewrote 1.7 GB of it to save space" is a different kind of statement
than "we cleaned up a cache". A defensible alternative is **never compact;
partition and archive instead** (§5).

### Q2 — What does replay mean *before* the boundary?

Today replay reconstructs state from full event payloads. After compaction, an
event before the boundary carries a reference instead. Replay then depends on
the referenced payload still existing.

This is answerable — the lean strip already does exactly this for new events,
and `hydrate_result_references` resolves them on the recovery paths. But it
converts replay from *self-contained* to *dependent on a second store*. That
dependency needs stating explicitly, because it is currently implicit and free.

⚠ And note where those payloads would live: `noetl.result_store` currently has
**`expires_at = NULL` on every row and no eviction job**. That is true today by
accident of nothing having been built, not by design. If compaction relies on it,
its retention becomes a load-bearing guarantee and must be made explicit.

### Q3 — How is the operation made restartable and verifiable?

1.7 GB is not one transaction. A design needs:

- **A boundary marker** — a watermark `event_id` below which rows are
  compacted, so a resumed run knows where it stopped, and a reader knows which
  regime an event is in without inspecting it.
- **Idempotence** — re-compacting an already-compacted row must be a no-op, so
  a crash mid-batch is safe.
- **Verification** — for each rewritten row, the referenced payload must be
  readable and byte-identical to what was removed, *checked before* the row is
  rewritten, not after. The lean strip already computes a `sha256` for exactly
  this; reuse it.
- **A dry-run mode** that reports what would change and the reclaim estimate
  without writing.

### Q4 — What is the rollback?

There is none once a row is rewritten, unless the original payload is retained —
which defeats the purpose. The only real answer is a **verified-before-write**
protocol plus a backup of the affected rows, and a backup of 1.7 GB is most of
the cost of just keeping it.

This asymmetry is the strongest argument for §5.

## 4. If it is done anyway — the shape

- Reuse `permanent_log_lean`'s existing transform so compacted rows are
  **byte-identical in shape** to newly-stripped ones. Do not invent a second
  representation.
- Work oldest-first in bounded batches, advancing a watermark.
- Per row: stage payload → verify by `sha256` → rewrite row → advance watermark.
  Never the other order.
- Emit `compaction_rows_total`, `compaction_bytes_reclaimed_total`,
  `compaction_verify_failed_total`, all pinned at 0. A verify failure must stop
  the run, not skip the row.
- Gate behind a flag that is off by default and requires an explicit boundary
  `event_id` — no "compact everything" default.

## 5. The alternative worth costing first

**Don't rewrite; partition and age out.**

`noetl.event` is already partitioned (`pg_total_relation_size` on the parent
returns 0 — a known trap, and evidence of partitioning). If old partitions can
be detached and archived to object storage, the space is reclaimed **without
mutating a single row**, and replay-before-boundary becomes "restore the
partition" rather than "resolve a reference".

That preserves the append-only invariant intact, and its rollback is
"re-attach". It should be costed before the compaction design is taken
seriously.

## 6. Recommendation

**Park it, and prefer §5 if the space is actually needed.**

The urgency is gone: the lean strip stops the problem growing, so the 1.7 GB is
now a fixed historical cost rather than a trend. Nothing about it is getting
worse. Spending an irreversible operation on a static cost is the wrong trade
unless disk is genuinely constrained — and if it is, detach-and-archive gets the
same space back without touching the invariant.

**What is worth doing now, cheaply:** measure it. Confirm the 1.7 GB figure and
its distribution across partitions, so the decision is made against a real
number and a real growth rate rather than a remembered one.
