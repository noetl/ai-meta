# ehdb#323 — Per-tier consistency invariants

**Status:** states what each tier guarantees **today**, grounded in the live
prod configuration and the code, not in intent. Where a stated invariant is
weaker than people assume, that is called out rather than smoothed over.

Live prod config this was written against (2026-09-01):

```
NOETL_EHDB_EVENTLOG   = primary      NOETL_EHDB_PROJECTION       = shadow
NOETL_EHDB_KV         = shadow       NOETL_EHDB_PROJECTION_READ_SOURCE = wal
NOETL_EHDB_OBJECT     = shadow       NOETL_EHDB_RECOVERY_SOURCE  = verify
NOETL_EHDB_TIER_QUERY_SOURCE = service
```

## The invariants that hold across every tier

1. **Single writer per shard.** Ordering is a global sequence assigned by one
   writer. ⚠ This rests **entirely on `StatefulSet replicas: 1`** — an
   orchestration preference, not a mutual-exclusion primitive. `ShardElection`
   is implemented and tested but has **no call sites**; the writer publishes
   `ehdb_election_active 0` to make that legible. Verified 2026-09-01: nothing
   (ScaledObject or HPA) targets the writer, and the IaC declares `replicas: 1`.
2. **Appends are ordered and gap-free within a shard.**
   `ehdb_l0_out_of_order_appends` is the canary and must stay 0.
3. **Parts are immutable once sealed.** Replication is therefore idempotent
   write-once copy; no consensus needed for the data path.
4. **`LATEST` is the only manifest read.** Versioned snapshots are write-only
   history — never read, and since ehdb#346 bounded (default `LATEST` + 32).

## Per tier

| tier | prod mode | read path | what it guarantees today |
| :-- | :-- | :-- | :-- |
| **event log (D1)** | `primary` | `TIER_QUERY_SOURCE=service` | Ordered, durable-on-one-disk at ack. **Serving is a separate decision from the mode flag** — `primary` names the tier, it does not by itself mean reads are served from it. |
| **projection** | `shadow` | `READ_SOURCE=wal` | Built and compared, **served from the WAL**. Divergence is measured, not acted on. ⚠ noetl/ai-meta#316: projection-parity has **no sampler**, so its divergence series only moves when a human queries the endpoint. |
| **KV** | `shadow` | — | Written alongside the incumbent; nothing reads it. |
| **object** | `shadow` | — | As KV. |
| **catalog** | live | direct | `catalog.jsonl` is a **separate tier holding registered catalog** — it is not event-derived and must never be truncated with event data. |

## Durability: the invariant most likely to be over-read

An ack means **one `fsync` on one disk**, not "replicated". The window from
ack to second failure domain is `seal_max_age` (5 s) **plus one sweep interval
plus upload**. Measured tail under load: ~5.25 s. **Alert above that, not at
it.**

⚠ And the substrate does not currently buy an independent failure domain:
`NOETL_EHDB_TIER_SERVICE_DIR` is nested inside `NOETL_EVENT_BUS_WRITER_DIR` on
one PVC (ehdb#332). Today "replicated" still means one disk. See
[322](322-quorum-ack-durability.md).

## Equivalence: what the oracle now means

As of server **v3.99.5** the fold digest is canonical for **sets as well as
maps** (noetl/ai-meta#314). Before that it reported ~73% divergence on
**100%-equivalent** data, because `HashSet` serialises to a JSON array in
per-process order.

Trusted baseline, 29 executions on v3.99.5, 2026-09-01:

```
same_version / applied_count / field census   29/29 (100%)
input events equal post-normalisation         29/29 (100%)
folded state identical                        29/29 (100%)
canonical_state_digest equal                  29/29 (100%)
remaining divergent paths                     NONE
```

**This is the reference the cutover gate compares against.** A digest
disagreement now means a real divergence, which was not true before.

## Recommended position for review

- **Do not promote any tier to primary-serve on durability grounds until
  ehdb#332** — a quorum over a shared PVC is not a quorum.
- **Single-writer is currently a deployment property, not an enforced one.**
  That is acceptable for a shadow tier and is the load-bearing risk for a
  serving one. Either wire `ShardElection` or accept the risk explicitly and
  in writing — the present state is neither.
- **The projection tier is not ready to be judged**, because #316 means it is
  only measured when observed. Fix that before treating its divergence rate as
  evidence of anything.
