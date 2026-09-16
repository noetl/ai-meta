# The event-log tier is `primary` on one zonal disk — options, and what each buys

**Status: OWNER DECISION ARTIFACT. Nothing here has been executed. No prod
change was made to produce it — every number is a read.**

Prepared 2026-09-16. This is the **event-log half of the substrate question**
that noetl/ai-meta#348 and the KV/object cutover proposal both defer to. It
folds in noetl/ehdb#322 (bound the D1 window), because that issue is asking for
a bound on a window whose shape this decision defines.

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

Not choosing. Not changing a storage class, not adding a snapshot schedule, not
flipping a backend — the first two are cheap and reversible but they are still
answers to a question the owner owns, and the third is the irreversible one.

The one thing I would do without further instruction is **(1)** above: verify the
Postgres-authoritative claim per read path, because every option's risk profile
depends on it and it is measurement rather than judgement.
