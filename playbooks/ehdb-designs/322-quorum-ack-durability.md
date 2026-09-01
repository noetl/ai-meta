# ehdb#322 — Synchronous quorum-ack: design and recommendation

**Status:** design only. Nothing here is implemented, and no durability
mechanism on prod changes as a result of this document.

## The problem, stated precisely

D1's durability window is the interval between a record being **acked to the
publisher** and that record reaching a **second failure domain**. Today an ack
means one thing: `append_batch` returned after an `fsync` on **one disk**.

That is not a theoretical gap. It was measured on prod 2026-08-30:
`ehdb_l0_unreplicated_age_seconds` climbed **387 → 404 → 451 → 497 s
monotonic** with 4 acknowledged records on a single disk, while
`ehdb_feed_total_lag 0` and `ehdb_l0_out_of_order_appends 0` reported perfect
health at the same instant. Losing the writer node in that window loses acked
records, and every health signal says green.

ehdb#329's age-seal trigger bounds *when a part seals*, which bounds when the
uploader can start. It does not make the ack wait for anything.

## Options

### A — leave it: asynchronous replication, bounded by age-seal (today)

- **Ack latency:** one local `fsync`, ~4 ms amortised under group commit.
- **Durability:** one disk until the seal + upload completes.
- **Loss window:** `seal_max_age` (5 s configured) **plus one sweep interval
  plus upload time**. Measured tail: ~5.25 s under load, unbounded on an idle
  shard before #329.
- **Cost:** zero.

### B — synchronous quorum-ack: hold the ack until N replicas confirm

- **Ack latency:** local `fsync` + slowest-of-quorum network round trip. On
  intra-zone GKE that is single-digit ms; cross-zone, tens.
- **Durability:** N failure domains at ack time. Loss window ~0.
- **Cost:** every publish pays the tail latency of the slowest replica in the
  quorum, and a quorum that cannot be formed **blocks writes**.

### C — hybrid: async by default, synchronous for a marked subset

- Ack synchronously only for records whose loss is unacceptable; everything
  else stays async.
- **Cost:** a policy surface — someone must decide, per record, which class it
  is, and that decision is a new way to be wrong.

## Recommendation: **B, with a hard precondition, or else stay on A**

Take B **only after the substrate provides an independent failure domain.**
It does not today. `NOETL_EHDB_TIER_SERVICE_DIR` lives **inside**
`NOETL_EVENT_BUS_WRITER_DIR` on **one PVC** (ehdb#332). A quorum across
replicas that share a disk is a quorum of one wearing a costume: it would add
the full latency cost of synchronous replication and buy **no** additional
durability, while looking like it had.

So the ordering is not negotiable:

1. **ehdb#332 first** — separate the substrate onto an independent volume.
   Until then B is strictly worse than A: same durability, higher latency.
2. **Then B**, quorum of 2 within a zone, behind a default-off flag, measured
   against A on the existing durability-window metric.
3. **Reject C** unless a concrete workload appears that needs it. It buys the
   latency of A for most records and the safety of B for some, at the price of
   a per-record policy decision that nothing today is equipped to make
   correctly. Complexity without a demonstrated caller.

## What "done" looks like

- `ehdb_l0_unreplicated_records` sits at **0** during steady state rather than
  sawtoothing, and `ehdb_l0_replicated_lag_seconds_count` **increments** —
  a count that never moves means nothing has *ever* replicated, which is what
  prod showed before #328.
- A positive control: kill a replica and confirm publishes **block** rather
  than silently degrading to single-disk acks. A quorum that quietly falls
  back is the same defect class as the ingest face that dropped errors.

## Related

- ehdb#328/#329 — the durability window instrument and the age-seal trigger
- ehdb#332 — the shared-PVC problem that gates all of this
- `agents/rules/representation-drift.md` — why "green health during a real
  durability gap" is the shape to design against
