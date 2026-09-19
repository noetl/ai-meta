---
spec: 2026-09-18-omni-multiregion-ehdb-M7
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M7 — Cross-region log replication + per-region re-derivation

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Copy sealed D1 parts to a second region's substrate, and **re-derive** D3 / D4 /
D5 there from the replicated log rather than replicating them.

⚠ **After M7 the second region is READ-ONLY.** It cannot take writes. That is
M8, and it is gated on fork F2b.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| replica targets | `NOETL_EHDB_REPLICA_TARGETS` | declarative list, `id=<id>,region=<r>,zone=<z>,uri=<…>;…` | single entry (today) |

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `ehdb-l0/src/engine.rs:316 open_replicated` | **VERIFIED** — *"Every immutable part + the durable manifest is written to all `replicas`; reads fall back across them"* | parse the flag into `Vec<ReplicaSpec>` |
| `ehdb-l0/src/catalog.rs PartMeta::replicas` | **VERIFIED** — the manifest **is** the replica-location catalog | records the second region |
| `ehdb-l0/src/substrate.rs DurableSubstrate` | **VERIFIED** — a plain ranged byte-sink; *"trivially pluggable — but the pluggable thing is the **substrate**, not the object store"* | needs a cross-region impl declaring `FailureDomain::Remote` |
| `ehdb-l0/src/engine.rs:436` cold-load | **VERIFIED** — *"a fresh node with no local data reproduces the exact record set + global sequence from the durable substrate — the fungible-writer property"* | the region-B read path |
| `ehdb-reference/src/projection.rs` | the D3 fold | re-derivation in region B |

## Why re-derive rather than replicate the derived tiers (fork F3)

D3 / D4 / D5 are deterministic folds of D1. The log is already being copied for
durability. Re-deriving avoids a second consistency contract, a second lag
metric and a second divergence class. **Recommended and proceeding.**

⚠ **With a standing caveat.** The natural cross-region equality oracle is the
existing cross-store parity comparator — and it has an **open** asymmetry
(`digest_mismatch`, plus `fold()` omitting `normalise_null_json` while
`fold_with_body()` calls it; both **VERIFIED** in `TRACE-RESULTS.md`). Using it
before those are closed would report a divergence that is **its own**. Until
then, region-equality must be proven by a purpose-built comparison on the read
path, not by the comparator.

## Interfaces / data shapes

No new record type. The manifest's `replicas` list grows entries. **VERIFIED**
that this is the designed seam: `ehdb-l0/src/lib.rs` — *"L0.1 writes a single
replica and designs the seam in (the `replicas` list + a per-part write loop);
N-way copy is the additive later step that appends more replica entries."*

## Entry criteria

- [ ] M0.5 exit (C4 — L0 must be the tier's store, or this replicates a store
      the tier does not use).
- [ ] M4 exit (survival goal).
- [ ] M6 exit (read routing, so the second region is reachable for reads).

## Exit criteria

- [ ] E1 — Sealed D1 parts land in a second region's substrate.
- [ ] E2 — A second-region reader **cold-loads** and reproduces the exact record
      set **and** `global_sequence` — the fungible-writer property.
- [ ] E3 — D3 / D4 / D5 in region B are re-derived from the replicated log and
      match region A over a fixed population. Publish the population. **Not via
      the parity comparator** (above).
- [ ] E4 — Replication lag published as a gauge **with an `as_of`**. *A number
      with no staleness signal is not evidence.*
- [ ] E5 — Region A's append hot path is unmeasurably affected. **VERIFIED**
      that this should hold: the uploader is asynchronous and *"a slow
      substrate never blocks the append hot path"* (`substrate.rs`) — E5 is the
      check that it still holds with a cross-region substrate, whose latency is
      an order of magnitude larger than the local case that property was
      designed against.
- [ ] E6 — Single-target config is byte-identical to today.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | the second target is configured but never written to | E1 — ⚠ check the **substrate**, not the manifest entry; a recorded `ReplicaLocation` with no bytes behind it is the representation-drift shape exactly |
| 2 | cold-load in region B recovers the record set but a **different** `global_sequence` | E2 |
| 3 | replication lag gauge published without `as_of` | E4 |
| 4 | the uploader becomes synchronous under a slow substrate | E5 |
| 5 | re-derivation in region B silently skips events it cannot hydrate | E3 |
| 6 | **Positive control** — make region B's substrate unreachable | E1 must go RED; if it stays green E1 is reading region A |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

More bytes copied. Region A's write path unchanged — but **E5 is the criterion
that verifies that claim rather than assuming it**, because the asynchrony was
designed against local-disk latency.

## Rollback

Drop the extra target from the flag. The manifest's `replicas` list shrinks;
parts already copied are harmless.
