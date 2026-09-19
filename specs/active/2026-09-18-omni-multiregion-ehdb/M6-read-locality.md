---
spec: 2026-09-18-omni-multiregion-ehdb-M6
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M6 — Read-locality routing / follower reads

Phase of [`spec.md`](spec.md). **Planning only.**
⭐ **This is the phase that delivers region-survivable READS.**

## Scope

Let a read be served by the **nearest** replica rather than the owner, gated on
that replica's closed timestamp satisfying the request's `VisibilityPlan`.

## The reuse that makes this small

**VERIFIED**, `ehdb-reference/src/affinity.rs`:

> *"Ownership decides **where** a write is allowed, never **whether** the event
> log is correct. A write that lands on a non-owner is **refused with no side
> effect**…; a read on a non-owner **cold-loads** the durable segments
> read-only."*

The follower-read **mechanism already exists**. M6 adds only the freshness
gate: without a closed timestamp, a non-owner read is fast and possibly stale
with no way to say by how much. With M3's closed timestamp it becomes a
*correct* bounded-staleness read.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| read locality | `NOETL_EHDB_READ_LOCALITY` | `owner` \| `nearest` | `owner` |

## Touch-points

| File | Change |
| :-- | :-- |
| `RouteResolver` (M0) | first non-default arm — pick a replica by `Locality` distance |
| `ehdb-reference/src/affinity.rs` | unchanged; supplies owner identity and the non-owner cold-load |
| `worker/src/ehdb/tier_query_source.rs:141 resolve()` | **VERIFIED** — returns 4 `Resolution` values; prod is `Service`. M6 adds replica selection *within* `Service`, it does not add a fifth variant |
| D8 `list_live_since` (M2a) | the membership view the resolver reads |
| M3 closed timestamp | the gate |

⚠ **Tier reads are pod-local.** Recorded in this program's memory as a prior
finding (`257-pr4-tier-query-multireplica`). Re-verify before assuming a
non-owner replica is reachable at all from the querying pod — if reads are
pod-local, "nearest" has no candidates and M6 silently degrades to `owner`,
which is a **false clean**, not a safe default. E4 exists for this.

## Interfaces / data shapes

```rust
pub struct ReplicaCandidate {
    pub id: String,
    pub locality: Locality,
    pub closed_ts: Option<Hlc>,   // None = unknown, never treated as fresh
}
```

⚠ `closed_ts: None` must mean **not eligible**, never "assume current". Same
fail-closed posture as `FailureDomain::Undeclared`.

## Entry criteria

- [ ] M3 exit (closed timestamp).
- [ ] M5 exit (**the gate** — single-writer must be a primitive first).
- [ ] M2a live (membership view).

## Exit criteria

- [ ] E1 — Under `nearest`, a read is served by a non-owner **only when** its
      closed timestamp satisfies the `VisibilityPlan`.
- [ ] E2 — Over a fixed population, follower and strong reads return identical
      results **modulo the declared staleness**. Publish the population and the
      idioms covered.
- [ ] E3 — When no replica qualifies, the read **falls back to the owner**, and
      the fallback is **counted**.
- [ ] E4 — The count of eligible candidates is published per read. A run where
      `candidates=0` on every read is a **failed** exit, not a passing one — it
      means `nearest` never engaged and E2 compared `owner` with `owner`.
- [ ] E5 — `ehdb_read_served_total{locality}` and
      `ehdb_read_fallback_total{reason}` pinned at 0 for every value,
      unconditionally.
- [ ] E6 — `owner` is byte-identical to today.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | `closed_ts: None` treated as eligible | E1 |
| 2 | staleness compared with the wrong sign (serves data **newer** than requested under `exact`) | E1 |
| 3 | fallback happens but is not counted | E3 |
| 4 | `nearest` silently always picks the owner | **E4** — this is the false-clean guard, and the most likely real failure |
| 5 | fallback metric emitted only on fallback | E5 |
| 6 | **Positive control** — a replica deliberately held far behind | must be excluded; if it serves, the gate is not on the path |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

Read path only; `owner` is today. The failure to fear is a stale read presented
as fresh, which E1/E4 and the `None`-is-ineligible rule exist to prevent.

## Rollback

Flag → `owner`.
