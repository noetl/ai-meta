---
spec: 2026-09-18-omni-multiregion-ehdb
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# Omni / multi-region EHDB — umbrella spec

**Planning only. No prod change, no running config touched, nothing merged to
`main`.** Design source:
[`OMNI-MULTIREGION-EHDB-PLAN.md`](../../../loops/active/2026-09-11-ehdb-resilient-core-phases/handover/OMNI-MULTIREGION-EHDB-PLAN.md).

This is the umbrella. One spec per phase lives beside it:

| Phase | Spec | Gating flag | Default |
| :-- | :-- | :-- | :-- |
| M0 | [`M0-resolvers.md`](M0-resolvers.md) | *(none — identity proof)* | — |
| M0.5 | [`M0.5-tier-backend.md`](M0.5-tier-backend.md) | `NOETL_EHDB_TIER_BACKEND` | `local_reference` |
| M1 | [`M1-locality.md`](M1-locality.md) | `NOETL_EHDB_LOCALITY` | unset |
| M2a | [`M2a-membership.md`](M2a-membership.md) | `NOETL_EHDB_MEMBERSHIP` | `off` |
| M2 | [`M2-hlc.md`](M2-hlc.md) | `NOETL_EHDB_HLC` | `off` |
| M3 | [`M3-closed-timestamp.md`](M3-closed-timestamp.md) | `NOETL_EHDB_READ_CONSISTENCY` | `strong` |
| M4 | [`M4-survival-goal.md`](M4-survival-goal.md) | `NOETL_EHDB_SURVIVAL_GOAL` | `zone` |
| M5 | [`M5-fencing-enforce.md`](M5-fencing-enforce.md) | `NOETL_EHDB_FENCING` | `shadow` *(exists)* |
| M6 | [`M6-read-locality.md`](M6-read-locality.md) | `NOETL_EHDB_READ_LOCALITY` | `owner` |
| M7 | [`M7-cross-region-replication.md`](M7-cross-region-replication.md) | `NOETL_EHDB_REPLICA_TARGETS` | 1 entry |
| M8 | [`M8-write-failover.md`](M8-write-failover.md) | `NOETL_EHDB_WRITE_FAILOVER` | `off` |

## Problem

NoETL's control-plane store is single-region and has no clock, no placement
policy and no read-freshness contract. The north star is a globally
distributed, multi-region, externally-consistent event store + serving layer.
The risk is not that the target is unreachable — it is that reaching it breaks
a tier that is already `primary` in production.

## Goals

- Port the **placement, leaseholder, MVCC-read and survival-goal** concepts from
  Spanner and CockroachDB onto EHDB's existing primitives.
- Every capability behind a flag, default OFF/SHADOW, additive on disk,
  independently shippable and independently reversible.
- Region-survivable **reads**.

## Non-Goals

- Raft, Paxos, 2PC, distributed transactions, MVCC version chains. See the
  plan §3 for the per-concept DECLINE reasons.
- Any general-purpose database feature. The layered-platform RFC's program
  invariant is unchanged by multi-region.
- Region-survivable **writes** without a resolved lease-authority fork (F2b).
- Re-scoping the in-flight stage-1 (projector / `digest_mismatch`) track.

## Constraints

Three, from the plan §2, and every spec below is downstream of them:

- **C1** — EHDB has no consensus and will not grow one for storage
  (`ehdb-l0/src/lib.rs:85`). **VERIFIED.**
- **C2** — ordering is leaderful per shard, and gaplessness depends on it
  (`ehdb-l0/src/engine.rs:712`). One writer per shard globally, at any instant.
  **VERIFIED.**
- **C3** — `FRAME_HEADER_LEN` is a fixed 12 bytes shared byte-identically with
  `durable_eventlog.rs`; widening it makes existing segments unreadable
  (`ehdb-reference/src/fencing.rs` deviation note). New fields go in the record
  body as `Option<T>` + `skip_serializing_if`, or in an out-of-band per-shard
  marker. **VERIFIED.**

Plus **C4**, added by the §0 correction:

- **C4** — the `primary`-serving event-log tier runs on
  `ehdb-reference::LocalReferenceEventLogDriver` over `ehdb-stream`, **not** on
  `ehdb-l0`. Any phase that extends L0 is inert on the tier until M0.5 lands.
  **VERIFIED** (`tier_store.rs:207`; `ehdb-reference/Cargo.toml` has no
  `ehdb-l0`; `ehdb-stream` deps are `ehdb-core`/`serde`/`serde_json`).

## Acceptance Criteria

- [ ] AC1 — Each phase spec below is `status: draft` with zero unresolved Open
      Questions before its implementation starts.
- [ ] AC2 — Under default configuration (every flag at its default), the system
      is **byte-identical and behaviour-identical to today**, demonstrated by
      M0's mutation battery, not asserted.
- [ ] AC3 — Every phase's proof is RED→GREEN with a **planted defect**: the
      check must be shown to fail before it is shown to pass.
- [ ] AC4 — No phase's proof uses the cross-store parity comparator or
      `/api/ehdb/projection-fold/diff/{id}` (see Verification Plan).
- [ ] AC5 — Every new metric pins its known label values at 0 **unconditionally**
      — never inside a config branch.
- [ ] AC6 — Every measurement publishes its **denominator**: the population
      measured and the idioms covered.
- [ ] AC7 — The F2b split is stated in every artefact that claims multi-region:
      **reads reach REGION; writes stay ZONE** until an embedded-consensus RFC
      resolves the lease authority.
- [ ] AC8 — No phase lands a prod change. Promotion of any flag past its default
      is owner-gated and out of scope for these specs.

## Plan / Task Breakdown

The phase order is the plan §5 dependency graph:

```
                 ┌─► M2 (needs M2a) ─► M3 ─┐
M0 ─┬─► M0.5 ─► M1 ─► M4 ─────────────────┼─► M5 ─► M6 ─► M7 ─► M8
    └─► M2a ──────────────────────────────┘
```

`M0.5` gates M1/M4/M7 (C4). `M5` gates everything to its right — nothing
multi-region is safe while single-writer rests on `replicas: 1`.

## Open Questions

None blocking. Three forks are **recommended-and-proceeding**, restated so a
future reader does not mistake a recommendation for a settled fact:

- **F1 clock** — HLC recommended; global sequencer and commit-wait declined.
  Revisitable at M2 without unwinding M0–M1.
- **F2b lease authority under region failure** — genuinely open. Recommended:
  home-cluster API server through M7; embedded lease-only consensus as its own
  RFC for M8; never a CAS over a store with no agreement underneath. **This is
  why AC7 exists.**
- **F3 derived-tier strategy** — re-derive per region, do not replicate.

## Verification Plan

Applies to every phase spec; each restates its specifics.

1. **RED→GREEN with a planted defect.** Write the check, plant the defect it
   claims to catch, observe RED, remove the defect, observe GREEN. A check that
   has only ever been green is indistinguishable from a check that cannot fire.
   ⚠ Four guards in this program's history were found enforcing the class they
   were written to prevent — most recently the `result_store, false` assertion
   that pinned the `keep_refs` defect.
2. **Green baseline first.** A mutation battery run against a red baseline reads
   every mutant as CAUGHT and proves nothing.
3. **Positive control.** A control that fails on its first run is doing its job.
4. ⛔ **Forbidden instruments.** Do **not** use the cross-store parity
   comparator or `/api/ehdb/projection-fold/diff/{id}` to prove any phase.
   Reasons, both recorded in
   [`TRACE-RESULTS.md`](../../../loops/active/2026-09-11-ehdb-resilient-core-phases/handover/TRACE-RESULTS.md):
   the snapshot-writer-vs-verifier `digest_mismatch` asymmetry is **open**, and
   the diff endpoint *"folds the tier's events, not the snapshot"* and so *"is
   not on the serve path"*. A proof built on either measures the instrument.
5. **Name the function measured**, and show it is on the path changed. v3.108.2
   shipped a correct hydration fix and its instrument moved by **0 of 40**
   because `compare_sources` was never on the path changed.
6. **Predict a number on a fixed population before running.**
7. **kind before prod**, always.

## Linked Issues

- (none yet — `spec-to-tasks` has not been run; this is planning only)
