---
spec: 2026-09-18-omni-multiregion-ehdb-M3
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M3 — Closed timestamp and bounded/exact-staleness reads

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Publish a per-shard **closed timestamp** and let a read ask for
bounded-staleness or exact-staleness against it. Default stays `strong`, which
is today.

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| read consistency | `NOETL_EHDB_READ_CONSISTENCY` | `strong` \| `bounded` \| `exact` | `strong` |
| default staleness | `NOETL_EHDB_MAX_STALENESS_MS` | integer ms | `0` |

A per-request override rides the read descriptor; the env var is only the
default.

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `ehdb-l0/src/unreplicated.rs UnreplicatedTracker` | **VERIFIED** — per shard, *"age of the **oldest** acknowledged record that is not yet durable"*, measured **from the append**, across the active unsealed part **and** sealed parts in flight | ⭐ **reuse as the closed-timestamp input.** It already computes the exact quantity |
| `ehdb-l0/src/catalog.rs` sealed-part watermark | `PartMeta` min/max sort key — **VERIFIED** | second input |
| `ehdb-l0/src/catalog.rs SparseIndex` + per-part min/max pruning | **VERIFIED** | reused unchanged for the `exact(ts)` prefix read |
| `VisibilityResolver` (M0) | degenerate | first non-default arm |
| `worker/src/ehdb/tier_store.rs` read paths | — | honour `VisibilityPlan` |

⚠ **Why `UnreplicatedTracker` and not `upload_lag_micros_total`:** the latter is
accumulated as `job.sealed_at.elapsed()` — measured from **seal**. A record
waiting in an unsealed active part contributes **nothing**. On a quiet shard the
pre-seal term is dominant and that metric is blind to it. **VERIFIED** from
`unreplicated.rs`'s own module doc: *"A dashboard built on it reads healthy in
precisely the scenario where events sit unreplicated."*

⚠ **Scope of the seal-age bound.** `NOETL_EHDB_SEAL_MAX_AGE_MS` is armed at
`5000` — **VERIFIED (manifest)**,
`ops/ci/manifests/noetl/cmdbus-writer-statefulset-prod.yaml:84`; not verified
against the live object — with two call sites, `worker/src/command_bus.rs:253`
and `worker/src/event_bus.rs:276`. Those are the **two buses**. The tier store
has no seal, no parts and no replication at all (C4), so on the tier the closed
timestamp depends on M0.5.

## Interfaces / data shapes

```rust
pub enum ReadConsistency { Strong, Bounded { max_staleness_ms: u64 }, Exact { at: Hlc } }

pub struct ClosedTimestamp { pub shard: u32, pub closed_at: Hlc, pub as_of: Hlc }
```

⚠ `as_of` is not decoration. *A number with no staleness signal is not
evidence* — `noetl.execution.status` read exactly like live data for months
after its writer was retired. A published closed timestamp must carry when it
was computed.

## Entry criteria

- [ ] M2 exit (`shadow`, i.e. every record carries an HLC).

## Exit criteria

- [ ] E1 — Per-shard closed timestamp published as a gauge, with its derivation
      documented and its **denominator printed** (shards sampled / shards live).
- [ ] E2 — Over a **fixed population** of ≥ N executions, a bounded-staleness
      read returns a result set that is a **prefix** of the strong read's.
      Publish N, and make a **numeric prediction before the run**.
- [ ] E3 — A request asking for a staleness the closed timestamp cannot satisfy
      is **refused**, not silently served stale. This is the criterion that
      matters: a silently-stale read is a wrong answer.
- [ ] E4 — `strong` is byte-identical to today, over the same fixed population.
- [ ] E5 — `ehdb_read_total{consistency}` pinned at 0 for all three values,
      unconditionally.

## Proof / verification

⛔⛔ **This phase has the strongest instrument prohibition in the program.**

Do **not** prove M3 with the cross-store parity comparator or with
`/api/ehdb/projection-fold/diff/{id}`. Both carry **open** asymmetries,
**VERIFIED** in
[`TRACE-RESULTS.md`](../../../loops/active/2026-09-11-ehdb-resilient-core-phases/handover/TRACE-RESULTS.md):

- `digest_mismatch` is a live snapshot-writer-vs-verifier content asymmetry
  that reproduces **with the projector off** (19→20 measured), so it is not the
  projector's and is not closed;
- `fold()` omits `normalise_null_json` while `fold_with_body()` calls it — a
  second, independent asymmetry on the same comparison;
- the diff endpoint *"folds the tier's **events**, not the **snapshot**"* and
  therefore *"is not on the serve path"*.

**Instrument the read path itself.** Log `stored_version`, `stored_digest`,
`bounded.version`, `bounded.digest` at the decision point, and name the
function measured. Precedent for why: v3.108.2 shipped a correct hydration fix
and its instrument moved by **0 of 40** because `compare_sources` was never on
the path changed.

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | closed timestamp computed from `upload_lag_micros_total` (seal-based) | a quiet-shard test where the unsealed term dominates |
| 2 | an unsatisfiable staleness request is served from the newest data anyway | E3 |
| 3 | `strong` silently routed through the bounded path | E4 |
| 4 | `as_of` omitted from the published timestamp | E1 |
| 5 | bounded read returns a **superset** (a record the strong read lacks) | E2 prefix property |
| 6 | **Positive control** — run E2 against a shard deliberately held behind | must go RED first run |

## Blast radius

Read-only. Default `strong` changes nothing. The failure mode to fear is a
**silently stale** read, which is why E3 refuses rather than degrades.

## Rollback

Flag → `strong`.
