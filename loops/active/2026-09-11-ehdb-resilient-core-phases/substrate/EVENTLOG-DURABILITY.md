# The event-log tier is `primary` on one zonal disk — options, and what each buys

**Status: DECIDED 2026-09-16 — option A adopted as the recorded production
stance; option D explicitly deferred. See §0. The body below is the analysis
that decision rests on and is unchanged from when it was an open artifact; no
prod change was made to produce it — every number is a read.**

Prepared 2026-09-16. This is the **event-log half of the substrate question**
that noetl/ai-meta#348 and the KV/object cutover proposal both defer to. It
folds in noetl/ehdb#322 (bound the D1 window), because that issue is asking for
a bound on a window whose shape this decision defines.

---

## 0. The decision (2026-09-16)

**Adopted: A — accept and record.** The event-log tier stays `primary` on a
single-zone disk. This is now the written production stance, not an open
question: a zonal loss costs the tier and forces a rebuild, and **Postgres
remains the authoritative business event log**, so the record itself survives
that loss independently.

What makes A a position rather than a shrug is that its load-bearing claim was
measured, not assumed (§4.1), and the rebuild path it depends on is **built and
deployed**, not hypothetical:

* Postgres is authoritative on every business event-log read path — verified
  live, and specifically searched for a #343-class "tier is the only copy"
  finding. There is none.
* The projection recovery ladder now has **Postgres as its final rung**
  ([noetl/server#441](https://github.com/noetl/server/pull/441)), merged and
  live in prod on `v3.112.3`. A tier that cannot answer no longer ends
  recovery — the rebuild has its ingredients wired in, which is exactly the
  gap §4.1 flagged as the caveat that made A weaker than it needed to be.
* The serve gate stays armed: a tier-derived projection may not serve unless a
  Postgres fold agrees with it, and #441's rung was deliberately kept **out of**
  `events_for_recovery` so the comparator keeps comparing against Postgres
  rather than against itself.

So A is adopted **on the strength of the recovery rung**, and that pairing is
the stance: *single-zone tier, Postgres-authoritative record, Postgres-backed
rebuild.* Drop any one of the three and this decision should be revisited.

**Deferred, explicitly: D — the durable segment stack with replicas.** D is the
one option here that is **not cleanly reversible** (data written in the new
format is unreadable by the old backend), it needs
[noetl/ehdb#321](https://github.com/noetl/ehdb/issues/321)'s fencing spec first
because replicas make election real, and it carries an on-disk migration. It is
not rejected — the architecture documents point at it — but it is a **separate,
dedicated owner decision** and is not implied by adopting A. Nothing in this run
moves toward it.

**B and C are untouched and remain available.** Both are cheap and reversible
and either can be added on top of A later without revisiting it. B (snapshots)
should not be taken until [noetl/ai-meta#262](https://github.com/noetl/ai-meta/issues/262)
settles whether the tier reader tolerates a torn tail, or it buys an untested
restore path. C (regional PD) needs a PVC migration and changes nothing about
the single-writer model.

**What adopting A changes operationally: nothing.** No storage class, no
snapshot schedule, no backend flag. That is the point — the cost of A is that
the exposure is now *written down and owned* instead of implicit.

**Open questions this does NOT answer** (still owner-scoped): §4.2, what RPO is
acceptable for the tier specifically; §4.3, whether a zonal outage is in scope
for this deployment at all — four disks in `us-central1-f` suggests the current
de-facto answer is no, and that may be deliberate.
[noetl/ehdb#322](https://github.com/noetl/ehdb/issues/322) (bound the D1
unreplicated window) stays open and is **answered by D, not by A** — under A
that window is not bounded, it is total, and the honest recording of that is
what A buys.

---

## 1. What is actually there

Measured, with a positive control on the tooling first — `gcloud compute disks
list` returns four disks, so the zeros below are absences rather than a silent
permission failure.

| fact | value |
| :-- | :-- |
| event-log tier backend | `LocalReferenceEventLogDriver` — JSONL. `tier_store::driver()` constructs it **unconditionally** |
| `NOETL_EHDB_EVENTLOG_BACKEND` | **unset on every prod workload** ⇒ fail-safes to `local_reference` |
| durable segment stack | **never opened** — hence `ehdb_replica_domains_observed 0`, correctly |
| writer replicas | **1** (`sts/noetl-cmdbus-writer`) |
| its volumes | 3 × `premium-rwo` (`pd-ssd`), `ReadWriteOnce` |
| disk scope | **zonal** — `premium-rwo` sets `type: pd-ssd` and **no `replication-type`** |
| all four prod disks | **`us-central1-f`. One zone.** |
| `reclaimPolicy` | **`Delete`** — removing the PVC removes the disk |
| VolumeSnapshotClass | **none configured** |
| PD snapshots | **0** |
| PD snapshot schedules (resource policies) | **0** |
| Backup for GKE plans | **0** (`Listed 0 items`, exit 0) |

`ehdb-reference`'s own doc on the backend in use: *"Default; correct for
`shadow`, **not production-durable under `primary`**."*

### Stated plainly

The authoritative event-log tier is **one JSONL file, on one zonal disk, in one
zone, attached to one pod, with no snapshot of any kind and a `Delete` reclaim
policy.** The server's embedded EHDB and the event-bus KV are on three more
disks **in the same zone**, so a zonal event does not degrade one component — it
takes all of them together.

⚠ **This is not an incident and nothing is lost.** A PD is durable storage with
its own intra-zone redundancy; the data is there and has been all along. The gap
is between the durability the word `primary` implies and what this substrate
provides, and between "we have not lost it" and "we could not lose it".

## 2. Why it is worth deciding now rather than later

Three things already point at it:

* **noetl/ehdb#321** gates any tier flip on a fencing spec. Fencing answers *who
  may write when several could*. Here **nothing could** — there is one writer and
  no replicas to elect between. The spec is easier to write, and far more useful,
  once §3 is chosen, because the failover semantics it must define depend on it.
* **noetl/ai-meta#348** found the kv/object shadow tiers on ephemeral storage.
  That is now fixed onto *this same substrate* — so the fix inherits whatever
  this decision concludes.
* **noetl/ehdb#322** asks to bound the D1 unreplicated window. Today that window
  is not bounded, it is **total**: there is no replica, so every write is
  unreplicated until the disk itself is gone. A bound is a meaningful ask only
  once there is something to replicate to.

## 3. The options

Ordered cheapest-first. None is recommended here — that is the decision.

### A. Accept and record

Keep the substrate. Write down that the event-log tier is `primary` on a
single-zone disk, that a zonal loss loses the tier, and that Postgres remains the
authoritative event log so the **business** record survives independently.

*Buys:* honesty, immediately, at no risk. *Costs:* nothing changes. *Rollback:*
n/a.

✅ **The check this option depended on has been done** (§4.1): Postgres is
authoritative for the business event log, and the projection serve path is
licensed by a Postgres fold. A tier loss costs a rebuild, not the data. That
moves A from "defensible if the claim holds" to **"defensible, claim verified"**,
and it is the cheapest honest position available.

### B. Snapshots

Add a `VolumeSnapshotClass` and a schedule (or PD resource policies). Turns
"gone" into "restorable to the last snapshot".

*Buys:* a recovery point, for a few lines of config. *Costs:* snapshot storage;
an RPO equal to the interval. *Rollback:* delete the schedule.
⚠ **A snapshot of an actively-appended JSONL file is crash-consistent, not
application-consistent.** Whether the tier's reader tolerates a torn tail is
noetl/ai-meta#262, which is open and undecided. Choosing B without settling that
buys a restore path nobody has tested.

### C. Regional disks

A storage class with `replication-type: regional-pd` replicates the block device
across two zones synchronously.

*Buys:* survives a zone loss, with no application change. *Costs:* roughly 2×
storage, some write latency; **requires migrating existing PVCs** (create new,
copy, cut over) — not an in-place edit. *Rollback:* the old disk still exists
until deleted.
⚠ This is the option most likely to be mistaken for free. It changes the failure
model at the block layer and leaves the single-writer application model exactly
as it is: still one writer, still no election, still no fencing.

### D. The durable segment stack with replicas

Set `NOETL_EHDB_EVENTLOG_BACKEND=durable_segment` and give it replicas — the
stack `build_durable_stack` already constructs, with the Phase-3 failure-domain
guard that is currently dormant precisely because nothing opens it.

*Buys:* application-level replication, a real answer to #322's window, and
`ehdb_replica_domains_observed` becomes a true signal instead of a correct zero.
*Costs:* the largest change here — a different on-disk format, a migration for
the existing tier, and it is the option that genuinely needs noetl/ehdb#321's
fencing spec first, because replicas make election real.
*Rollback:* the flag is one variable, but **the data written in the new format is
not readable by the old backend** — so rollback means accepting the loss of
whatever was written after the flip, or a reverse migration.

⚠ **D is the only option on this list that is not cleanly reversible**, and it is
the one the architecture documents point toward. That tension is the decision.

## 4. What I would want answered before choosing

1. ~~**Is Postgres genuinely still authoritative for every event-log read
   path?**~~ **ANSWERED 2026-09-16 by measurement. Yes — with one nuance that
   makes option A stronger than this section originally allowed.**

   | read path | source |
   | :-- | :-- |
   | business event log (`noetl.event`) | **Postgres authoritative.** `/api/executions/{id}` and `/api/ehdb/executions/{id}/events` both read it; the tier is a mirror |
   | projection **recovery fold** (`events_for_recovery`) | **tier, on 100% of calls.** Postgres is not in that chain |
   | projection **serve** | **licensed by a Postgres fold** — a tier-derived projection may not serve unless it agrees with one |

   Measured live: `recovery_fold_total{outcome="spine_incomplete",source="spine"} 2`
   and `{outcome="folded",source="tier"} 2`, with
   `recovery_source_info{mode="tier"} 1`. The code records the same at a far
   larger denominator: spine `25,390 spine_incomplete, 0 folded`.

   The serve gate is armed and clean — `projection_serve_refusal_total` is **0**
   across all four reasons including `digest_mismatch`. Its comment records that
   it *used* to fold the recovery ladder and therefore compared a tier-derived
   fold against a tier-derived record: *"A tier missing events agrees with
   itself and is granted a serve."* Folding Postgres is what can see a gap in
   the mirror.

   **No #343-class finding.** Nothing serves event data from the tier as the
   only copy without a Postgres check behind it. I looked for one specifically.

   ⚠ **The caveat, and it is the useful part.** `fold_from_postgres` exists and
   works but is **not wired into `events_for_recovery`**. So a tier loss makes
   recovery **refuse** — fail-safe, not a wrong answer, and not data loss. The
   events are in Postgres; rebuilding from them is a **wiring job, not a
   recovery operation**.

   **This makes option A materially more defensible than §3 claimed.** Accepting
   the substrate does not mean accepting that a zonal loss destroys the
   projection — it means accepting a rebuild step that already has its
   ingredients.

   ✅ **And that wiring step is now built and kind-proven** —
   [noetl/server#441](https://github.com/noetl/server/pull/441), open for review.
   The recovery ladder gains Postgres as its final rung, so a tier that cannot
   answer no longer ends recovery. RED→GREEN on one execution:
   `wal_present false → true`, `wal_verdict stored_behind_spine → match`, with
   `recovery_fold{source="postgres",outcome="folded"}` appearing only on the new
   build. The comparator was verified unchanged **at runtime**, not merely by a
   source guard: `refold_endpoint` still reports `spine_refused` on the same
   execution rather than quietly succeeding via Postgres.

   ⚠ The rung is deliberately NOT in `events_for_recovery`, which the comparator
   folds — putting it there would let a tier missing events fold correctly from
   Postgres, agree with the stored record, and disappear from the one comparator
   that exists to find it. Server-only; independent of the writer pin.
2. **What RPO is acceptable for the tier specifically**, given the business
   record is in Postgres?
3. **Is a zonal outage in scope at all** for this deployment? Four disks in
   `us-central1-f` says the current answer is no, and that may be deliberate.

## 5. What I am not doing

**Superseded in part by §0 — A is now chosen.** What remains true of this
section: still not changing a storage class, still not adding a snapshot
schedule, still not flipping a backend. Adopting A is a recording, not an
action, and B, C and D all stay unexecuted.

Not choosing. Not changing a storage class, not adding a snapshot schedule, not
flipping a backend — the first two are cheap and reversible but they are still
answers to a question the owner owns, and the third is the irreversible one.

The one thing I would do without further instruction is **(1)** above: verify the
Postgres-authoritative claim per read path, because every option's risk profile
depends on it and it is measurement rather than judgement.
