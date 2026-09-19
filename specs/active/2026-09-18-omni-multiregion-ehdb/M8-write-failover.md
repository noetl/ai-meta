---
spec: 2026-09-18-omni-multiregion-ehdb-M8
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M8 — Region-survivable writes — **blocked on fork F2b**

Phase of [`spec.md`](spec.md). **Planning only.**

## ⚠⚠ The honest statement this spec exists to carry

> **Reads reach REGION at M6/M7. Writes stay ZONE until an embedded-consensus
> RFC resolves the lease authority.**

This sentence belongs in every artefact that claims NoETL is multi-region.
Anyone reading "multi-region" as "writes fail over automatically" will be wrong
for the entire life of M0–M7, which is most of this program.

## Scope

Move a shard's write leadership between regions, with the old leader's writes
**refused** by Invariant F.

## The blocker — fork F2b, genuinely open

**VERIFIED**, `ehdb-reference/src/election.rs:23-26`:

> *"The API server's compare-and-swap on `resourceVersion` **is** the mutual
> exclusion, and etcd behind it already is the Raft cluster. Running a second
> consensus cluster adds operational surface without adding a guarantee."*

That reasoning is correct **and per-cluster**. Losing the region hosting that
API server means no writer can be elected anywhere.

| Option | Pro | Con | Verdict |
| :-- | :-- | :-- | :-- |
| **A. Home-cluster API server is the lease authority** | zero new machinery; works today | that cluster is a cross-region dependency; write failover blocked when it is lost | ⭐ **take this through M7** |
| **B. Leases in EHDB over a D4-KV CAS** | self-sufficient | needs consensus EHDB does not have and will not build (C1). **A CAS with no agreement underneath is not a CAS** | ⛔ **never** |
| **C. Embedded consensus scoped to lease records only** (~KB of state) | genuinely region-survivable; the *"proven library, not hand-rolled"* shape [`self-sufficiency.md`](../../../agents/rules/self-sufficiency.md) prescribes | a new dependency and a new operational surface | **its own RFC, when M8 is actually wanted** |

⛔ **M8 does not start until F2b is resolved in writing.** Starting it under
option A would ship a failover that cannot fire in the one scenario it exists
for — the defect class this program keeps finding.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| write failover | `NOETL_EHDB_WRITE_FAILOVER` | `off` \| `manual` \| `auto` | `off` |

⭐ **Recommendation: ship `manual` and stop.** `auto` requires trusting a
failure detector to decide a region is gone, and a wrong decision is a
split-brain on the tier that is `primary`. `manual` gets the availability
benefit with a human in the loop. `auto` is not in this spec's scope.

## Touch-points

| File | Change |
| :-- | :-- |
| `ehdb-reference/src/election.rs` | leadership handoff across regions; `LeaseRecord.holder` carries the region (M1) |
| `ehdb-reference/src/fencing.rs` | unchanged — Invariant F is already exactly the mechanism that must refuse the old leader |
| the per-shard fencing marker | unchanged; the epoch stays a monotone `u64` |
| `RouteResolver` (M0) | write target follows the new holder |

## Interfaces / data shapes

**No new type, deliberately.** The epoch stays a monotone `u64` and **the
region is an attribute of the holder, not of the epoch**. Widening the epoch
into a `(region, term)` tuple would require a total order across regions —
which is the thing there is no coordinator for, i.e. it would smuggle F2b back
in as a data-shape decision.

## Entry criteria

- [ ] M7 exit.
- [ ] **A written decision on F2b.** This is a hard gate, not a checklist item.

## Exit criteria

- [ ] E1 — Shard leadership can move to region B.
- [ ] E2 — The epoch advances **monotonically across the move**: the new
      holder's `transitions` strictly exceeds the old.
- [ ] E3 — The old holder's writes are **refused** by Invariant F. This is the
      payoff of M5 and the criterion that distinguishes a failover from a
      split-brain.
- [ ] E4 — A **manual** failover exercised in kind, with the write-unavailability
      window **measured**, not estimated.
- [ ] E5 — `off` is byte-identical to today.
- [ ] E6 — `ehdb_leadership_transitions_total{from_region,to_region}` and
      `ehdb_write_unavailable_seconds` pinned at 0, unconditionally.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | the old holder keeps writing and is **accepted** | E3 — the split-brain case |
| 2 | epoch resets or repeats across the move | E2 |
| 3 | failover succeeds while the old holder is merely *unreachable*, not *fenced* | E3 — unreachable is not stopped |
| 4 | the unavailability window is reported from the flag flip rather than from the last successful write | E4 |
| 5 | **Positive control** — a partitioned old leader that keeps appending locally | must be refused on rejoin; if its writes land, everything above is decorative |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

⚠⚠ **Maximal.** Moves the single writer of a `primary` tier. C2 says
gaplessness depends on there being exactly one; a failover that leaves two is
not a degraded mode, it is divergence.

⚠ Also: `chain_heads` is per-replica and a standby runs the armed sweeps, so a
cutover needs a deliberate serving gap (recorded as 30–60 s in the #332
program notes). Budget it; do not discover it.

## Rollback

Flag → `off`. Leadership stays where it is. ⚠ Rollback does **not** undo a move
that already happened — it prevents the next one. Moving leadership back is a
second failover, not an undo.
