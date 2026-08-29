# RFC — an embedded relational-projection layer inside EHDB, for NoETL's internal data only

**Status:** design exploration. No code, no prod change, no cutover.
**Date:** 2026-08-29
**Companion to:** `docs/rfc/postgres-to-ehdb-internal-data.md`

**Owner direction:** *"A dedicated relational model support for noetl relations only
in EHDB — concept inspired by Spanner Omni (a downloadable, self-managed,
PostgreSQL-dialect, distributed database that runs outside Google Cloud). But ONLY
for NoETL internal projections, distributed AND embedded into noetl core, with very
limited functionality covering only noetl's needs — NOT a general relational
database."*

This RFC **directly revisits** the companion RFC's §4 claim that the catalog and
credential store should stay in Postgres "because they're relational". That claim
was weaker than it sounded. §1 below is the evidence.

---

## 1. Requirements — what NoETL's internal relational surface *actually* is

Read out of the code, not assumed. Counts are from the `noetl/server` crate.

### 1.1 Catalog — `src/db/queries/catalog.rs`

The whole access pattern:

```sql
-- latest version of a path
SELECT <cols> FROM noetl.catalog
 WHERE path = $1 [AND archived_at IS NULL]
 ORDER BY version DESC LIMIT 1;

-- a specific version
SELECT <cols> FROM noetl.catalog WHERE path = $1 AND version = $2 [AND archived_at IS NULL];

-- list, optionally by kind
SELECT <cols> FROM noetl.catalog [WHERE kind = $1] [AND archived_at IS NULL]
 ORDER BY created_at DESC;

-- next version on register
SELECT (COALESCE(MAX(version), 0)::smallint + 1)::smallint FROM noetl.catalog WHERE path = $1;

DELETE FROM noetl.catalog WHERE ...;
```

**"Latest version per path" is `ORDER BY version DESC LIMIT 1`, not a window
function.** The companion RFC implied a `DISTINCT ON`/`ROW_NUMBER` shape. It is an
equality predicate, a sort, a limit, one `MAX`, and a nullable-column filter — over
**1,469 rows**. That is not a relational workload; it is a keyed lookup with an
ordering.

⚠ One real dialect dependency: the code introspects `information_schema.columns` to
feature-detect `archived_at`. Any replacement must answer that or the soft-delete
feature-flag logic breaks.

### 1.2 Credential / keychain — `src/db/queries/credential.rs`

```sql
SELECT id, name, type, data_encrypted AS data, ... FROM noetl.credential WHERE name = $1;   -- by alias
SELECT ... FROM noetl.credential WHERE name ILIKE $1 OR description ILIKE $1;               -- search
SELECT ... FROM noetl.credential;                                                            -- list
```

Point lookup by key, a substring search, a list. **21 rows.** `keychain` is 806 rows
with the same shape.

### 1.3 Runtime (worker registration) — `src/services/runtime.rs`

```sql
SELECT runtime_id FROM noetl.runtime WHERE kind = $1 AND name = $2;
UPDATE noetl.runtime SET ... ; INSERT INTO noetl.runtime (...) ; DELETE FROM noetl.runtime WHERE kind = $1 AND name = $2;
SELECT name FROM noetl.runtime WHERE ...;   -- sweeps
```

Compound-key upsert + delete. **127 rows.**

### 1.4 Projection snapshot — `src/services/orch_snapshot.rs`

Exactly **one** `INSERT INTO noetl.projection_snapshot` site (guarded by a test that
counts it), read back by `execution_id`. Append + keyed read.

### 1.5 What genuinely needs more

The crate as a whole uses `JOIN` ×54, CTEs ×614, window functions ×9, `GROUP BY`
×10, `HAVING` ×8, `ON CONFLICT` ×28, `RETURNING` ×31.

**But that complexity is overwhelmingly in the event/execution/dashboard paths, not
in the four stores above.** And transactions are narrower still:

```
explicit begin()/commit() sites: 6 — ALL in src/handlers/events.rs
```

**Transactions are used for event writes only.** The catalog, credential, keychain
and runtime stores do **no** multi-statement transactions today. That is the single
most important requirement finding in this RFC.

### 1.6 The minimal surface

| needed | not needed (for these stores) |
| :-- | :-- |
| `SELECT` with equality + `AND`/`OR` predicates | JOINs across internal tables |
| `ORDER BY … LIMIT` | window functions, CTEs |
| `MAX()` over one column | `GROUP BY` / `HAVING` |
| `INSERT`, `UPDATE`, `DELETE` by key | multi-statement transactions |
| `IS NULL` / `IS NOT NULL` | `ON CONFLICT` (used elsewhere, not here) |
| `ILIKE` substring match | subqueries, `UNION` |
| types: text, smallint, bigint, timestamptz, jsonb | full PG type system |
| minimal `information_schema.columns` | the rest of the catalog |

That is perhaps **fifteen** SQL constructs. The owner's "very limited functionality
covering only noetl's needs" is not hand-waving — it is a genuinely small target.

---

## 2. The key architectural insight — does fold-based distribution hold?

**The claim:** distribution comes from the event-sourcing itself. Every node
deterministically folds the shared, already-ordered EHDB event log into its own
local relational projection. You get distributed relational *reads* without
distributed consensus, because **ordering was already established by the event-log
tier** — which is exactly what Spanner spends Paxos-per-transaction achieving.

**Assessment: the insight holds, for reads, and it is the strongest part of this
proposal.** Three reasons it is credible here specifically:

1. **The ordering primitive already exists and is proven.** The event-log tier is
   `primary` and serving, with `global_sequence` as a total order and a
   cross-store comparator showing 8,476 events compared, 0 divergence.
2. **Determinism is already tested.** `canonical_state_digest` and the 6-verdict
   `ReFoldVerdict` vocabulary exist precisely to assert that two independent folds
   of the same events agree. That machinery is the correctness proof this design
   needs, and it was built for a different reason.
3. **The read-mostly stores dominate.** Catalog 1,469 rows, credential 21, keychain
   806, runtime 127. A full local fold is milliseconds and megabytes.

### 2.1 Where it does **not** hold: the writes

The four stores are **not** all read-mostly, and this is the crux:

| store | write shape | fits fold-to-local? |
| :-- | :-- | :-- |
| `projection_snapshot` | derived from events | ✅ **perfectly** — it already *is* a fold |
| `catalog` | operator registers a playbook | ⚠ mutable, but low-rate and naturally an event (`catalog.registered`, `catalog.archived`) |
| `runtime` | worker heartbeat/registration | ⚠ high-rate, ephemeral, TTL-ish — an event log is a poor fit for heartbeats |
| `credential` / `keychain` | operator rotates a secret | 🔴 **worst fit** — see §4.4 |

**Writes must go through the event log**, or the local projections diverge and the
whole determinism argument collapses. That is fine for catalog (a registration *is*
an event) and natural for projection_snapshot. It is questionable for `runtime`
(heartbeats as durable log entries is a write-amplification problem — 127 workers ×
heartbeat interval, forever) and it is actively wrong for credentials (§4.4).

### 2.2 The consistency model you actually get

**Read-your-writes is not free.** A node that registers a playbook and immediately
reads it back must either block until its own fold catches up, or read through to
the log. This is the same lifetime/coverage problem as noetl/ai-meta#307, one layer
up — and #307 is currently *unsolved*, which is a warning about how easy this class
of thing is to get subtly wrong.

Practically: catalog registration → execute is exactly that pattern, and it happens
constantly.

---

## 3. Build options

### (a) Minimal SQL/PG-dialect layer in Rust over the projection tier

Fold events → local relational store → hand-written query surface (§1.6).

- ➕ Exactly the owner's brief; no external dependency; composes directly with the
  tier/fold/comparator machinery already built.
- ➖ You are writing a query engine. Even fifteen constructs means a parser, a
  planner (however trivial), predicate evaluation, type coercion, NULL semantics,
  and `information_schema` shims. And every future need re-opens it.
- ➖ **The dialect trap:** "PostgreSQL-dialect" is not a bounded target. `::` casts
  appear 7,520 times in this crate, `AT TIME ZONE` 15 times, `jsonb` 30.

### (b) Embed an existing engine as the local projection store, fed by folds ⭐

Fold events → **SQLite** (or DuckDB) → query with real SQL.

| engine | PG-dialect fit | embeddable in Rust | licence | verdict |
| :-- | :-- | :-- | :-- | :-- |
| **SQLite** (`rusqlite`/`libsql`) | *not* PG dialect, but covers §1.6 entirely | ✅ excellent, in-process, single file or `:memory:` | public domain | **recommended** |
| **DuckDB** | analytic; OLTP-ish point lookups weaker | ✅ good Rust bindings | MIT | good if analytics matter |
| **pglite / PG-wire embedded** | true PG dialect | ⚠ WASM/Postgres-in-process is heavy and immature in Rust | varies | not yet |
| **`gluesql`/`datafusion`** | partial SQL, Rust-native | ✅ | Apache-2 | plausible middle ground |

- ➕ Zero query-engine code. Transactions, indexes, NULL semantics, `LIKE` all free.
- ➕ A local file per node is *exactly* the fold-to-local model.
- ➖ Not PG dialect — the ~15 constructs port trivially, but the
  `information_schema` introspection and `::`/`AT TIME ZONE` usages need a shim or
  rewriting at the call sites.
- ➖ Adds a C dependency to the worker/server image.

### (c) Run Spanner Omni as a backend

- ➕ Real PG dialect, real distributed transactions.
- ➖ It is a *distributed database you operate* — the opposite of "embedded into
  noetl core". It would replace Postgres with something heavier, and re-introduce
  the external dependency the vision is trying to remove.
- **Not recommended.** Useful as the *conceptual* reference (self-managed,
  PG-dialect, runs outside Google Cloud) rather than as the component.

### Recommendation: **(b) with SQLite**, folded from the EHDB event log

The owner's requirement is "limited functionality covering only noetl's needs".
Option (b) delivers that by *borrowing* a proven engine rather than writing one, and
the dialect gap is ~15 constructs over four small tables. Option (a) is the same
outcome with a query engine you now own forever; option (c) is not embedded.

The interesting work is then the **fold → relational materialiser** and the
**determinism guarantee**, not SQL parsing — which is where the value actually is,
and where the existing comparator machinery already applies.

---

## 4. Feasibility, effort, risk — the honest parts

### 4.1 The dialect scope is the hidden cost

`::` cast syntax appears 7,520 times crate-wide. Most is not in these four stores,
but "PG-dialect compatible" invites unbounded scope. **Bound it explicitly to §1.6
and treat anything else as a call-site rewrite**, or this becomes a
Postgres-reimplementation project.

### 4.2 Consistency: catalog registration is the sharp edge

Register-then-execute needs read-your-writes. Options: block on fold catch-up
(latency on a hot path), read-through to the log for catalog specifically, or accept
a bounded staleness window and make it visible. **This must be designed, not
discovered** — noetl/ai-meta#307 is a live example of a fold-vs-lifetime mismatch
that shipped and served nothing for weeks without anyone noticing.

### 4.3 Transactions: better news than expected

Only 6 explicit transaction sites, **all** in the event-write path. The four stores
need none today. So a local engine with single-statement atomicity is sufficient —
**provided** that stays true. Worth a guard test asserting no transaction is opened
against these stores.

### 4.4 ⚠ The credential store — my earlier concern **persists**, and an embedded engine does not resolve it

I raised this in the companion RFC and the owner's direction does not dissolve it,
so I will restate it plainly rather than let it pass:

- **Event-sourcing a secret store means the history *is* the log.** Every rotation
  appends; nothing is ever truly deleted. Revocation becomes "append a tombstone",
  and the superseded ciphertext lives forever in the replicated log. That is the
  opposite of what a credential store should do — and tonight's incident is a live
  demonstration of why permanence of credential material matters.
- **Distribution makes it worse**, not better: fold-to-local means every node holds
  a full local copy of the credential projection.
- **The bootstrap cycle stays.** The wallet needs a credential to read credentials.
  Today that is broken by `POSTGRES_PASSWORD` + CSI files
  (noetl/ai-meta#267 stage 5). An embedded store changes where the cycle lands, not
  whether it exists.

**Recommendation: exclude `credential`/`keychain` from this design.** They are 21 +
806 rows — the smallest stores in the inventory and the least worth moving. Keep
them in Postgres, or move them to a secret manager directly, but do not event-source
them. This should be an explicit, stated exception in the vision rather than an
unexamined omission.

### 4.5 `runtime` is a poor fit for different reasons

Heartbeats are high-rate, ephemeral, and TTL-shaped. Appending every heartbeat to a
durable replicated log is write amplification for data whose value expires in
seconds. Either keep it out, or model it as node-local state that is never folded.

### 4.6 Where Postgres remains pragmatic even under this vision

- **Ad-hoc operator SQL during incidents.** Tonight's diagnosis used exactly that.
  Whatever remains must stay queryable by a human with `psql`, or the migration buys
  data locality at the cost of a much worse debugging story.
- **`result_store`** — business data, explicitly out of scope, and genuinely
  relational.
- **`credential`/`keychain`** — §4.4.

### 4.7 Effort, honestly

Option (b) is not small. Fold→materialiser, schema definition per store, the
read-your-writes design, a determinism guarantee equal to the existing
`ReFoldVerdict` work, call-site rewrites for dialect gaps, and a shadow-then-compare
rollout per store. This is a **multi-month programme**, not a sprint — and its first
prerequisite is not code (§5).

---

## 5. Sequencing against #307 and the migration roadmap

**This is a parallel *design* track but a strictly *downstream* build track.**

```
#307 recovery serves            ← PREREQUISITE for everything below
   └── projection tier proven with real comparator coverage
          └── fold→relational materialiser (this RFC), shadowed
                 └── catalog on EHDB relational projection
                        └── runtime / small tables (if at all)
                               └── (credential/keychain: excluded, §4.4)
```

**Why #307 gates it:** this entire design rests on "deterministic folds of an
ordered log produce agreeing local state". Today the projection recovery fold
**serves nothing** — every read is `spine_refused`, comparator coverage is zero. You
cannot build a relational layer on a fold whose correctness you currently cannot
measure.

That also sharpens the #307 choice further than the companion RFC did:

- **Option 3** (accept in-flight-only recovery) does not merely fail to align — it
  **forecloses this RFC entirely**, because there would be no working fold to
  materialise from.
- **Option 2** (comparator reads the WAL/tier directly) is the one that yields the
  measurement infrastructure this design needs.

**Recommended immediate step: none of this. Resolve #307 first**, then prototype the
fold→SQLite materialiser for `catalog` alone, behind a shadow comparator, and
measure divergence before proposing a cutover.

---

## 6. Summary

- The **requirements are genuinely small** — ~15 SQL constructs over four tables,
  and the catalog is a keyed lookup, not a relational workload. My earlier
  "it's relational, leave it in Postgres" was overstated for the catalog.
- The **fold-based distribution insight holds for reads** and is well supported by
  machinery that already exists. It does **not** hold uniformly for writes.
- **Recommended build: embed SQLite as the local projection store, fed by
  deterministic folds** — borrow the engine, own the materialiser.
- **Exclude credentials/keychain** and probably `runtime`; say so explicitly.
- **#307 is the prerequisite**, and option 3 would foreclose this design.

## 7. Not done

No code, no dependency added, no prod change. Tactical items remain parked pending
the owner: the #307 option choice, the weak-credential rotation
(`playbooks/secret-manager/ROTATE-WEAK-DB-CREDENTIALS.md`), and the dead-data
cleanup (`outbox`, `projection`).
