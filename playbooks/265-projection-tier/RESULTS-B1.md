# ai-meta#265 phase B1 — read-serve kind gate results

**Date:** 2026-08-24 · **Cluster:** kind-noetl, 3 worker replicas + writer StatefulSet ·
**Images:** `localhost/noetl-server:265b1`, `localhost/noetl-worker:265b1`, built from
[server#355](https://github.com/noetl/server/pull/355) and `noetl/worker` **v5.121.0**
(the merged phase-A code, not the pre-rebase branch).

**Prod was not touched.** Verified read-only on exit — see §6.

## Result — 8 arms, 129 assertions, 0 failures

| arm | read source | what it proves | result |
| :-- | :-- | :-- | --: |
| `baseline` | `postgres` | the default costs nothing: `disabled` counted, `served_tier` flat | **14 / 14** |
| `verify` | `verify` | the tier serves, and the state is **byte-identical** to the incumbent's | **20 / 20** |
| `tier` | `tier` | same, without reading the incumbent first | **20 / 20** |
| `ahead` | `tier` | **the dangerous case**: a record above the event tip demotes | **16 / 16** |
| `corrupt` | `tier` | a record whose digest does not describe its body demotes | **15 / 15** |
| `behind` | `verify` | a record below the incumbent demotes as `stale_version` | **15 / 15** |
| `unavailable` | `tier` | a black-holed relay demotes, the incumbent answers | **13 / 13** |
| `load` | `tier` | 48 concurrent read+write passes: nothing lost, duplicated or reordered | **16 / 16** |

Comparator controls `controls_ok=true`, `unexpected=0`, `expected=9` before **and**
after every arm — so the zeros above are readable rather than merely absent.
All 13 read-outcome series present and pinned at 0 before each arm.

Reproduce: `./run-read-gate.sh <settled_execution_id>`.

## What each arm established

**The serve is real and it is correct.** `served_tier` moved on every healthy
arm, and the assertion with teeth is not that it moved: it is that the
incumbent's `checksum` is **unchanged** after a rebuild that resolved its
snapshot from the tier. `/api/internal/projection/advance` rebuilds from
whatever the read resolved and re-saves, so a wrong body changes the digest
while the version stays put. A version-only check passes a wrong body.

Measured separately, because the assertion depends on it: the digest **is**
deterministic — four advances of a settled execution produced one checksum.

**The demote fires on all four wrong-tier shapes, and each is named as itself.**

| mutation | outcome recorded | why the distinction matters |
| :-- | :-- | :-- |
| record at `max(event_id) + 100000` | `version_ahead` | the only reason that means *serving would have been wrong* — the events in between would never be folded |
| record whose `checksum` does not describe its `snapshot` | `checksum` | same version, different content; a count- or version-based check passes this |
| record at `incumbent − 1` | `stale_version` | correct to serve and still refused: `verify`'s contract is agreement |
| relay black-holed | `unavailable` | the tier is not *wrong*, it is *absent* |

In every mutation arm `served_tier` stayed flat and the state served was the
incumbent's, verified by digest. **A demote that still served the bad snapshot
would satisfy every counter assertion**, so the digest check is what makes these
arms mean anything.

**Under load** (48 concurrent `advance` passes, each a read then a write of the
same row): `served_tier +48`, zero fault-class demotes, content and version
identical afterwards, 49 tier records whose versions **never descend by store
order**.

**Tier 1 never moved.** Compared against a baseline captured at the start of
each arm, not against the literal `match` — see the harness findings.

## Harness findings (six, each of which produced a wrong answer first)

These are recorded separately from the platform findings because a harness bug
reported as a platform finding is the worst way for a gate to be wrong.

1. **The tier-1 assertion demanded `match` absolutely.** An execution from
   2026-08-18 is legitimately `divergent` on tier 1 (1 of 130 events absent,
   from before the event-log mirror was armed). The gate scored that as *"arming
   tier 2 moved tier 1"* — the most alarming thing it can say, and it was false.
   Now baseline-relative, with a guard that the baseline is itself a real
   verdict so "did not move" cannot be satisfied by two identical
   non-measurements.

2. **`unavailable` cannot assess tier 1 at all.** That arm black-holes the relay
   *both* comparators read. Reported as NOT ASSESSABLE rather than as a pass —
   the tier-1 claim for that arm comes from a post-restore re-check.

3. **Truncating the tier store no longer empties the tier.** worker#280 gave it a
   runtime cache: after `: > projection.jsonl` the file held 3 lines while the
   relay still served 15 records. **This invalidates phase A's `drop` arm on
   worker ≥ v5.121.0.** `deploy.sh reset-tier` now truncates *and* restarts the
   writer. The general shape is this issue's own theme one level down — the
   store **file** is a representation of what the tier serves, and nothing forces
   the two to agree once a cache sits between them.

4. **A crafted record shadows the next arm.** The read path picks the newest by
   (version, sequence), so the `ahead` record was still newest during `corrupt`
   and the gate reported `version_ahead` where it expected `checksum`. Every
   mutation arm now runs on a reset tier.

5. **`bump-incumbent` is sticky.** A version raised by SQL **survives a
   recompute** — `advance` floors at the snapshot's own version — so the
   incumbent stays above the event-log tip and every later arm turns into
   `version_ahead`. The `behind` arm was rewritten to append *below* the
   incumbent instead; `deploy.sh pin-incumbent` is the honest undo.

6. **awk cannot compare snowflake ids.** `348221780836704257 > 348221780836704256`
   is *equal* in awk — doubles carry ~15–16 significant digits. The gate reported
   "the incumbent is not ahead" about an incumbent that was ahead by 1, while the
   demote it was corroborating had already fired correctly. Same family as
   `authoritative_sequence` not accepting a snowflake.

Two more, from earlier in the session: the event-log parity route is
`/executions/` (**plural**) — the singular 404s, and an empty body reads as "no
verdict" and scores a FAIL against tier 1; and the content assertions require a
**settled** execution, since one still gaining events legitimately produces a
different state. The gate now checks settledness and reports INCONCLUSIVE rather
than failed.

## What this gate does NOT establish

- **G4's coverage counter never fired end-to-end here.**
  `noetl_ehdb_projection_snapshot_gate_total` is present and pinned at 0, and it
  stayed at 0: this cluster carries a ~672k-command backlog and its executions do
  not reach `trigger_orchestrator_inner`. A counter that has never once fired is
  indistinguishable from one that cannot fire, so the gate logic was extracted
  into a pure `snapshot_gate_outcome` with four unit tests (including a
  positive control that it *opens*). **The end-to-end path remains unexercised
  and must be watched on the first prod shadow.**
- **G3 is not addressed.** The mirror is still a synchronous awaited POST inside
  `orch_snapshot::save`. No latency measurement was taken here; the kind cluster's
  backlog makes it the wrong place to measure dispatch latency anyway.
- **No multi-replica *server* claim.** kind runs one server replica, so this says
  nothing about two servers racing the same row. The 48-way concurrency is
  in-process.
- The gate worker is **not DuckDB-capable** (`--features duckdb-integration`
  dropped). Nothing on the read or mirror path touches DuckDB.

## §6 — prod verification on exit

Unchanged from the session start:

- `NOETL_EHDB_PROJECTION_MIRROR_SOURCE`, `NOETL_EHDB_PROJECTION_PARITY_ENABLED`,
  `NOETL_EHDB_PROJECTION_READ_SOURCE` — **0 occurrences** on any prod workload.
- `NOETL_EHDB_EVENTLOG=primary` on all three worker deployments.
- No rollout: newest prod rollout remains 2026-08-19.
