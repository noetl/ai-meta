---
spec: 2026-09-18-multiregion-ehdb-M2
status: draft
created: 2026-09-18T19:20:00Z
owner: claude-opus-5 (ai-meta session 2026-09-18)
---

# M2 — HLC clock substrate, in SHADOW

Phase of [`spec.md`](spec.md). **Planning only.**

## Scope

Introduce a Hybrid Logical Clock, stamp a commit HLC on every append, and read
it nowhere. M2 establishes the clock; M3 is the first phase that uses it.

**Recommended over the alternatives (fork F1), decided inline:** HLC, not
GPS/atomic-clock hardware (we have none, and no path to it on GKE Autopilot),
and not a global sequencer (a cross-region round trip on the write path, and
exactly the external-service dependency
[`self-sufficiency.md`](../../../agents/rules/self-sufficiency.md) forbids).

## Flags

| Flag | Env var | Values | Default |
| :-- | :-- | :-- | :-- |
| clock | `NOETL_EHDB_HLC` | `off` \| `shadow` \| `on` | `off` |
| commit-wait | `NOETL_EHDB_COMMIT_WAIT_MS` | integer ms | `0` (off) |
| max offset | `NOETL_EHDB_MAX_CLOCK_OFFSET_MS` | integer ms | `500` |

`commit_wait` is offered and **recommended to stay 0**: a wait is only as sound
as ε, and an unmeasured ε buys a false guarantee — worse than none.

## Touch-points

| File | Current | Change |
| :-- | :-- | :-- |
| `ehdb-l0/src/dataset.rs:164 EventRecord` | `{global_sequence, execution_id, transaction_id, payload, event_id: Option<String>}` — **VERIFIED** | add `commit_hlc: Option<u64>` |
| `ehdb-l0/src/engine.rs:732` append | `let seq = self.global_sequence + 1` — **VERIFIED** | stamp the HLC; **`global_sequence` remains the sort key, unchanged** |
| `ehdb-reference/src/eventlog.rs` append path | the tier's driver | same field, same policy (needs M0.5 for the L0 backend; the field itself rides the record body either way) |
| new — `HlcClock` | — | beside, **not inside**, `server/src/snowflake.rs` |
| `ehdb-gossip` / D8 | M2a | supplies the peer set the offset halt reads |

## Interfaces / data shapes

```rust
/// 48-bit physical ms since the NoETL epoch ‖ 16-bit logical counter.
pub struct Hlc(u64);

impl HlcClock {
    pub fn now(&self) -> Hlc;              // monotone even under a backwards wall clock
    pub fn observe(&self, remote: Hlc);    // advances on receipt
    pub fn offset_millis(&self) -> i64;    // vs the peer set
}
```

⛔ **Do not reuse the snowflake timestamp as the HLC.** **VERIFIED**
(`server/src/snowflake.rs`): snowflake is 41-bit ms ‖ 10-bit machine id ‖
12-bit per-ms sequence, with **no logical component and no uncertainty bound**.
Conflating them silently weakens both.

⚠ **`global_sequence` is per-engine, not global.** **VERIFIED** —
`engine.rs:732` assigns `self.global_sequence + 1`, recovered as
`manifest.max_sequence()` (`:405`, `:483`); it is gapless *because a single
writer serialises* (`:712`). A second region's engine would mint the same
integers. The HLC is what makes cross-shard and cross-region comparison
meaningful; the sequence is not, and must stop being read as a global order.

## External consistency — the honest version

Achieved by **restart-on-uncertainty** — a read that falls inside the
uncertainty interval is retried at a higher timestamp — rather than by waiting
out the interval on every commit.
Two commitments make it a mechanism rather than a decoration:

1. ε is **configured and observed**: `ehdb_clock_offset_millis` gauge, **pinned
   at 0**. A clock guarantee whose offset is unmeasured is a representation with
   nothing forcing it to agree with reality.
2. A node detecting offset > ε/2 against its D8/gossip peer set **halts,
   fail-closed**. This is why M2a is a hard prerequisite: without a peer set the
   halt **cannot fire**, and an unfirable safety check is precisely the defect
   class this program keeps finding.

## The `deny_unknown_fields` audit

Same gate and same denominator as [`M1`](M1-locality.md#the-deny_unknown_fields-audit--with-its-denominator):
**151 occurrences across `ehdb/crates`**, audited **per struct**. `EventRecord`
already has it removed (**VERIFIED**, `dataset.rs:154`) and so does
`EventLogAppendOutcome` (`ehdb-reference/src/eventlog.rs:142`) — but the full
path of a record from producer to disk to tier-service reply crosses more
structs than those two. Publish the count examined.

**Expand-first, ordered:** tolerate-unknown release deployed everywhere →
*then* the stamping release. ⚠ Merged is not deployed.

## Entry criteria

- [ ] M1 exit.
- [ ] **M2a exit** — the peer set must exist before a halt that reads it.

## Exit criteria

- [ ] E1 — Under `shadow`, **100 %** of new appends carry `commit_hlc`.
      Publish appends observed / appends stamped.
- [ ] E2 — **Nothing reads it.** Proven by mutating the stamp to a constant and
      observing **no** behavioural test change. (A read that appears here is a
      phase-ordering violation, not a bonus.)
- [ ] E3 — A rollback binary reads records carrying `commit_hlc` without error
      — run explicitly against the previous release's binary.
- [ ] E4 — `ehdb_clock_offset_millis` live and **pinned at 0**.
- [ ] E5 — HLC monotonicity survives (a) a process restart and (b) a backwards
      wall-clock step, under test.
- [ ] E6 — `NOETL_EHDB_COMMIT_WAIT_MS=0` ⇒ zero added latency, measured.

## Proof / verification

| # | Planted defect | Must go RED in |
| :-- | :-- | :-- |
| 1 | HLC goes backwards on a wall-clock step back | E5(b) |
| 2 | HLC resets to 0 on restart | E5(a) |
| 3 | logical counter never increments within one ms ⇒ duplicate HLCs | uniqueness test |
| 4 | offset halt reads an **empty** peer set and concludes "healthy" | the halt test — ⚠ this is the M2a dependency made concrete; a zero-peer "no disagreement" is a false clean |
| 5 | `commit_hlc` serialised as `0` rather than skipped when absent | E3 byte-compat |
| 6 | **Positive control** — a node with a deliberately skewed clock | must halt; if it does not, the halt cannot fire |

⛔ Forbidden instruments: cross-store parity comparator;
`/api/ehdb/projection-fold/diff/{id}`.

## Blast radius

8 extra bytes per record. `global_sequence` untouched. The halt (E4/proof 6) is
the one behaviour that can stop a node — it is **default-inert** because
`NOETL_EHDB_HLC=off`, and arming it in prod is owner-gated.

## Rollback

Flag → `off`. Records already written keep an unread field.
