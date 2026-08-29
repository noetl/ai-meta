# RFC — move NoETL's internal orchestration data to EHDB; keep Postgres for business results

**Status:** design only. Nothing here has been executed and nothing changes prod.
**Date:** 2026-08-29
**Owner direction:** *"why do we still use Postgres for noetl INTERNAL orchestration
data? All that should go to EHDB; only user/business result data should stay in
Postgres."*

This reframes the pending decision on noetl/ai-meta#307 — see §5.

---

## 1. What is actually in Postgres today

Measured on the prod `noetl` database, 2026-08-29. Sizes are
`pg_total_relation_size`, so index + toast included.

### (a) NoETL-INTERNAL / orchestration

| store | size | rows | what it is |
| :-- | --: | --: | :-- |
| `command` + 16 partitions | **~8.4 GB** | — | command queue. **Still written** — newest row was seconds old at time of measurement. |
| `event` + 12 partitions | **~2.9 GB** | — | the durable event log |
| `outbox` | 247 MB | 32,387 | transactional outbox for the retired NATS publisher. **Last write 2026-06-11**, 0 unpublished — dead. |
| `result_ref` | 80 kB | — | pointers into the result store |
| `execution` | 107 MB | — | execution records. Status column frozen since the Python retirement (noetl/ai-meta#235). |
| `frame` | 63 MB | — | control-flow frames |
| `catalog` | 33 MB | 1,469 | registered playbooks |
| `projection_snapshot` | 4.8 MB | 1,981 | the real projection store (noetl/ai-meta#265) |
| `projection` | 32 kB | **0** | dead table, no Rust writer (noetl/ai-meta#265) |
| `keychain` | 1 MB | 806 | keychain entries |
| `credential` | 128 kB | 21 | encrypted credential store |
| `runtime` | 184 kB | 127 | worker registration / heartbeat |
| `plugin_module` | 792 kB | — | WASM plug-ins |
| `stage`, `transient`, `manifest`, `manifest_part`, `sink_pending`, `subscription_dedup`, `schedule`, `resource`, `secret_audit`, `object_store`, `temp_ref` | < 1 MB each | — | assorted control-plane state |

### (b) Genuine USER / BUSINESS result data

| store | size | what it is |
| :-- | --: | :-- |
| `result_store` | **172 MB** | the results playbooks write. **Actively written.** |

### The headline

**Roughly 97% of the bytes in this database are internal orchestration, not business
results.** `command` + `event` alone are ~11.3 GB against `result_store`'s 172 MB.

The owner's framing is not aspirational tidiness — Postgres is currently, by volume,
almost entirely a NoETL-internals store that happens to also hold the results.

---

## 2. What is ALREADY on EHDB, precisely, right now

Being exact here matters, because the configuration reads more advanced than the
behaviour.

| concern | configured | actually serving |
| :-- | :-- | :-- |
| **command bus** | `NOETL_COMMAND_BUS=ehdb` | ✅ EHDB carries commands. `noetl.command` is still written and still growing (~8.4 GB). |
| **event log — serve** | EHDB event-log tier is `primary` | ✅ serving; `crossstore_events_compared{tier=eventlog}` = 8,476, 0 divergence |
| **event log — durable copy** | `noetl.event` mirrored | ⚠ **unverified, see §6** |
| **control-flow DRIVE reads** | off-server state builder, `NOETL_STATE_BUILDER=offserver`, source `ehdb` | ✅ WAL/EHDB-sourced |
| **control-flow RECOVERY read** (`load_latest`) | `NOETL_EHDB_PROJECTION_READ_SOURCE=wal` | 🔴 **serving nothing.** `projection_read_total{served_tier}` = 0; every attempt is `spine_refused` (noetl/ai-meta#307) |
| **projection store** | — | 🔴 Postgres only — `projection_snapshot`, 1,981 rows, actively written |
| **catalog** | — | 🔴 Postgres only |
| **credential / keychain** | — | 🔴 Postgres only |
| **runtime registration** | — | 🔴 Postgres only |
| **outbox** | — | ⚪ Postgres, but **dead** since 2026-06-11 |

**The honest summary:** the *transport* moved to EHDB. The *durable stores* largely
did not. And the one recovery path that was flipped to EHDB (`READ_SOURCE=wal`)
serves nothing at all — so today EHDB is the bus and the serving tier for the event
log, while Postgres remains the system of record for essentially every other
internal concern.

---

## 3. Roadmap

Ordered by *dependency*, not by size. Each step names what it needs from the owner.

### Step 0 — delete the dead weight (safe, incremental)

`outbox` (247 MB, dead since 2026-06-11, 0 unpublished) and `projection` (0 rows,
no writer) are pure residue from the NATS era. Dropping them is a schema change with
no reader — the cheapest possible win, and it makes the inventory honest.

**Risk:** low. **Decision needed:** confirm nothing external reads them.

### Step 1 — make EHDB recovery actually work (this IS noetl/ai-meta#307)

Nothing else on this roadmap is safe until the recovery read serves. Today the
comparator has **zero coverage**, so there is no evidence base for any further
cutover — you would be flipping stores with no working comparison between them.

See §5 for how the #307 options map onto this vision.

**Risk:** medium. **Decision needed:** #307 option 1 or 2 (option 3 abandons the
vision — see §5).

### Step 2 — projection store to EHDB (consequential cutover)

`projection_snapshot` is the incumbent and is actively written. The EHDB projection
tier exists, is mirrored, and its lag is well inside the window — but it serves
nothing, for the same reason as step 1.

Sequence: recovery works (step 1) → comparator gets real coverage → shadow until
divergence is provably zero across a representative window → flip serve → retire
the Postgres writer.

**Risk:** high — this is control-flow state. **Decision needed:** explicit
per-stage go, same discipline as the event-log flip.

### Step 3 — command queue (largest by volume, likely easiest by semantics)

`noetl.command` is ~8.4 GB and still written, yet the command **bus** is already
EHDB. This strongly suggests the Postgres table is now a durability/audit copy
rather than the dispatch path. If so, its retirement is mostly a retention decision,
not a cutover.

**Risk:** medium, pending the write-path audit. **Decision needed:** is
`noetl.command` still load-bearing, or already a shadow? Answer that first — it may
be the single biggest, cheapest reduction available.

### Step 4 — catalog (its own migration question)

The catalog is 1,469 rows of playbook definitions, read on every execute and written
by registration. It is small, but it is *queried relationally* — latest-version-per-
path, filters by path prefix, soft-delete via `archived_at`. See §4.

**Risk:** medium. **Decision needed:** whether EHDB should serve read-mostly
reference data at all, or whether this is where Postgres legitimately stays.

### Step 5 — credential / keychain (do NOT move casually)

21 credentials and 806 keychain entries, encrypted at rest with
`NOETL_ENCRYPTION_KEY`. This is the most security-sensitive store in the system and
the one with a structural dependency: **the wallet reads the credential table over
Postgres, and Postgres needs `POSTGRES_PASSWORD`** (noetl/ai-meta#267 Tier 2). Any
move must not create a bootstrap cycle.

**Risk:** high. **Decision needed:** whether the gain justifies re-homing the
encryption boundary at all. My recommendation is **no, not soon** — see §4.

### Step 6 — the small control-plane tables

`runtime`, `stage`, `transient`, `manifest*`, `sink_pending`, `subscription_dedup`,
`schedule`, `resource`, `secret_audit`, `object_store`. Sub-megabyte, mostly
ephemeral or registration state. Individually cheap; collectively they are what
"Postgres holds only business data" actually requires.

**Risk:** low-medium each. **Decision needed:** per table, and only after steps 1–3
prove the pattern.

---

## 4. Where Postgres may still be the right tool — argued honestly

The goal should be *"Postgres holds what genuinely needs a relational database"*,
not *"Postgres holds nothing"*. Four cases where the answer is not obvious:

**1. The catalog.** Read-mostly reference data queried by predicate — latest version
per path, prefix filters, `archived_at IS NULL`. EHDB is a log-structured event
store; "latest version per path across 1,469 rows with a soft-delete filter" is a
relational query, and reimplementing it as a fold is work with no obvious payoff. A
33 MB table read on every execute is not the problem worth solving.

**2. The credential store.** Beyond the bootstrap-cycle risk, this store is
*mutable by design* (rotation, revocation) and tiny. Event-sourcing a secret store
means the plaintext history is the log — which is precisely the property you do not
want. **I would leave this in Postgres and say so explicitly in the vision**, rather
than leave it as an unstated exception.

**3. `execution`.** Already frozen and misleading (noetl/ai-meta#235). The right move
is probably to **delete** it rather than migrate it — status is derivable from the
event log, and a second source of truth is what made it wrong.

**4. Anything a human queries ad hoc.** Operators run SQL against this database
during incidents — tonight included. Whatever remains must stay queryable, or the
migration trades a data-locality win for a much worse debugging story.

Conversely, the clear-cut cases *for* moving: `command`, `event`, `projection_snapshot`,
`outbox`. These are append-heavy, time-ordered, replayable — exactly what EHDB is.
They are also ~97% of the bytes. **The volume argument and the semantic argument
point the same way**, which is rare and worth acting on.

---

## 5. ⚠ How this reframes noetl/ai-meta#307

#307 asks how to fix projection recovery having zero coverage. Its three options
were presented as roughly equivalent engineering choices. **Under this vision they
are not:**

| #307 option | alignment |
| :-- | :-- |
| **1 — spine route rehydrates on miss** | ✅ aligned. Makes EHDB recovery actually serve; the smallest step onto the roadmap. Cost: adds up to `deadline_ms` on a route the comparator polls. |
| **2 — point the comparator at the WAL/tier directly** | ✅✅ most aligned. Removes the lifetime mismatch at its source rather than papering over it, and is the shape the rest of the roadmap needs anyway. Larger change. |
| **3 — accept and document that recovery covers in-flight executions only** | ❌ **not aligned.** It codifies Postgres as the recovery system of record and abandons the internal-data-on-EHDB direction. Legitimate as a decision, but it is a decision *against* this vision, not a neutral one. |

**Recommendation: option 2**, with option 1 acceptable as an interim if the latency
cost is unwelcome. Choosing 3 is fine — but it should be chosen knowingly, as a
scope decision, not as the cheap option.

---

## 6. Open questions I could not resolve

Recording these rather than guessing.

1. **Is `noetl.event` still being written?** `max(created_at)` returns `NULL` on
   partitions holding 180 MB and 2.5 GB, repeatably. Either `created_at` is NULL for
   those rows — itself worth a look — or the aggregate is being defeated some other
   way. Until this is answered, the event log's durable-copy status is **unknown**,
   and step 3's premise for `command` should be re-checked the same way.
2. **Is `noetl.command` dispatch-path or audit-copy?** Determines whether step 3 is
   a retention decision or a cutover. Answerable by auditing writers.
3. **What still reads `frame` (63 MB) and `execution` (107 MB)?** Both look like
   Python-era structures.
4. **Does anything outside NoETL query this database?** Determines how free the
   schema changes in steps 0 and 6 really are.

## 7. What this RFC does not do

No cutover, no flag, no schema change, no prod effect. Every step above needs its
own gate, and steps 2, 3 and 5 need explicit per-stage owner approval on the same
terms as the event-log flip.
