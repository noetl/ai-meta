# RFC — code-defined, versioned relations inside EHDB (get / put / filter, no SQL)

**Status:** design exploration. No code, no dependency, no prod change.
**Date:** 2026-08-29 · **Revision 2** — supersedes the SQL/SQLite proposal in rev 1.
**Companion:** `docs/rfc/postgres-to-ehdb-internal-data.md`

**Owner direction (rev 2):** *"We don't need PG dialect at all. We query only the
relations we have. A new relation = a new version of EHDB. Support only the query
types we need — it can be simple get / put / and some filters, exposed as an API."*

This removes the largest cost and the largest risk in rev 1. Recorded plainly
because it matters: **rev 1 recommended embedding SQLite and treating
"PostgreSQL-dialect" as the compatibility target. That is now dropped entirely.**
No query language, no parser, no planner, no dialect surface. The `::` cast
appearing 7,520 times crate-wide was the warning sign that "PG-dialect compatible"
is unbounded; rev 2 does not attempt it.

---

## 1. The constraint is the design

Three rules, and each one deletes a category of work:

1. **Relations are defined in EHDB's own code.** A fixed, typed set. No runtime
   DDL, no user-defined tables, no schema catalogue to interpret.
2. **A new or changed relation is a new version of EHDB.** Schema evolution is
   software release, reviewed and deployed like any other change.
3. **Each relation exposes a small typed API** — `get` by key, `put`, and a named
   filter or two — not a query language.

This is deliberately **not a general database**, and the constraint is what makes
it tractable: there is no optimiser because there are no ad-hoc queries; no type
coercion because the types are Rust types; no dialect because there is no dialect.

⚠ The honest cost of rule 2: **anything not anticipated requires a release.** For a
product's own internal schema that is a reasonable trade — it is how the event
envelope is already versioned. It would be an unreasonable trade for user data,
which is exactly why `result_store` stays out of scope.

---

## 2. The per-relation API surface — from the real code

Derived from the public functions in `noetl/server`'s query modules, which *are*
the existing API. This is the whole surface.

### 2.1 `catalog` — 1,469 rows

| operation | key / filter | today |
| :-- | :-- | :-- |
| `get_latest(path)` | by `path`, highest `version`, non-archived | `ORDER BY version DESC LIMIT 1` |
| `get(path, version)` | composite key | equality |
| `get_by_id(catalog_id)` | surrogate key | equality |
| `list_versions(path)` | by `path`, ordered | equality + sort |
| `list(kind?)` | filter on `kind`, ordered by `created_at` | equality on an indexed field |
| `next_version(path)` | `MAX(version)` for a path | trivially the latest key |
| `put(entry)` | append a new version | insert |
| `archive(paths)` / `restore(paths)` | set/clear a marker | soft delete |
| `delete(paths)` | hard delete | delete |

**Indexes needed: `path` (primary, with `version`), `kind` (secondary), plus an
`archived` flag.** No joins, no aggregates beyond "highest version for a key" —
which in a key-ordered store is just *"last entry in the `path` prefix"*, i.e. free.

### 2.2 `projection` — 1,981 rows

| operation | key |
| :-- | :-- |
| `get(execution_id)` | primary key |
| `put(execution_id, snapshot)` | written **by the fold**, one site today |

The smallest possible surface, and already a fold by construction.

### 2.3 Explicitly out of scope

| relation | why |
| :-- | :-- |
| `credential`, `keychain` | §5.3 — event-sourcing secrets is wrong regardless of storage |
| `runtime` | §5.4 — heartbeat write-amplification; its API is also the largest (9 methods incl. `heartbeat`, `cleanup_stale`) |
| `result_store` | business data, out of scope by the vision |
| `event`, `command` | already EHDB concerns, not relations |

**So the initial target is two relations with roughly a dozen operations between
them.** That is the true size of this project.

---

## 3. Storage — the recommendation changes, and gets smaller

Rev 1 recommended embedding SQLite. **Without SQL, SQLite's query engine is the
entire reason to take the dependency — so the recommendation no longer holds.**

| option | assessment |
| :-- | :-- |
| **(a) Build on the existing EHDB tier primitives** ⭐ | **Recommended.** `ehdb-l0` already describes itself as a *"replicated object-store layer: immutable parts + ClickHouse-style meta-catalog + hot-local/durable-async tiering… **noetl-internal only (fixed datasets)**"*. That is this RFC's philosophy, already written down and shipped. `StoreTier` is already a code-defined enum (`Eventlog`, `Projection`) — **adding a relation is adding a variant, which is literally "a new version of EHDB"**. There is also an existing KV tier (`ehdb/kv.rs`) with `mirror_put` / `serve_primary_cycle`. **Zero new dependencies.** |
| (b) Embedded KV crate — `redb` / `sled` / `fjall` | Sound, and `redb` in particular is a good fit (pure Rust, single file, typed tables, secondary indexes by convention). But none is in the dependency tree today, and it duplicates tiering, replication and the fold/comparator machinery that `ehdb-l0` already provides. Take this only if (a) proves structurally unable to carry keyed reads. |
| (c) SQLite / DuckDB | **Withdrawn.** Justified only by a query engine that is no longer required. |
| (d) Spanner Omni | Still not embedded; still a database you operate. Conceptual reference only. |

**Recommendation: (a).** `StoreTier` becomes the code-defined relation registry; each
relation gets a typed accessor module; the existing tier service, mirror, and
comparator carry replication and verification unchanged.

---

## 4. Distribution — unchanged, and the strongest part

Each relation is a **deterministic fold of the shared, already-ordered event log
into a per-node local projection**. Reads are local. No consensus.

This works here specifically because ordering is *already solved*: the event-log
tier is `primary` and serving, `global_sequence` is a total order, and the
cross-store comparator reports 8,476 events compared with 0 divergence. Spanner
spends per-transaction Paxos establishing what the event log has already
established — so the expensive part is simply absent.

The correctness proof also already exists: `canonical_state_digest` and the
6-verdict `ReFoldVerdict` vocabulary were built to assert that two independent folds
of the same events agree. That is precisely the guarantee a relation-per-fold design
needs.

### 4.1 ⭐ The elegant consequence: adding a relation needs no data migration

Because a relation is **only** a fold of the log, a new EHDB version that introduces
a relation simply **folds the existing log into it on boot**. There is no backfill
job, no dual-write window, no migration script, no schema-change downtime.

The log is the source of truth; relations are disposable derived state. A relation
can be dropped and rebuilt, its shape changed in a release, or a bug in its fold
fixed and the relation simply recomputed — none of which is a data migration.

⚠ Two honest caveats on that elegance:

- **Rebuild cost is bounded by log length, not relation size.** A 1,469-row catalog
  folded from a multi-GB log is cheap only if the fold can seek or the log is
  compacted. Worth measuring before relying on boot-time rebuilds.
- **It only holds for relations whose entire content is derivable from the log.**
  If any relation accepts a write that is not an event, the property is lost — which
  is precisely why §5.1 insists writes go through the log.

---

## 5. Writes, and the hard parts that remain

### 5.1 Writes go through the event log

`put` → append event → fold → local relation. Any direct write to a local relation
breaks determinism, and with it §4.1's no-migration property. This must be an
enforced invariant, not a convention — a guard test asserting a single write path
per relation, in the same spirit as the existing test that counts
`INSERT INTO noetl.projection_snapshot` sites.

### 5.2 ⚠ Read-your-writes — still the sharpest edge

Register a playbook, then immediately execute it. That is a constant pattern, and
under fold-based writes the local relation may not yet reflect the write.

Options, none free:

1. **Block until the local fold reaches the write's `global_sequence`.** Simple,
   correct, adds latency to registration.
2. **Read-through to the log for the catalog specifically** when a sequence newer
   than the local fold is requested.
3. **Return the write's sequence to the caller** and let the caller pass it on the
   subsequent read (a read barrier / "read at ≥ N").

Option 3 is the most honest — it makes the consistency contract explicit at the API
rather than hiding it — and it composes with the typed API since `put` can simply
return a sequence.

⚠ This must be **designed**, not discovered. noetl/ai-meta#307 is a live example of
a fold-vs-lifetime mismatch that shipped, served nothing for weeks, and was found
only by reading metrics that happened to be zero.

### 5.3 Credentials and keychain — the exclusion stands

The owner's clarification does not touch this objection, so restating it rather than
letting it lapse:

- **Event-sourcing a secret store makes the history *be* the log.** Rotation
  appends; revocation becomes a tombstone; superseded ciphertext persists forever,
  and fold-based distribution replicates it to **every node**.
- **The bootstrap cycle moves rather than disappears.** The wallet needs a
  credential to read credentials; today that is broken by `POSTGRES_PASSWORD` +
  CSI files (noetl/ai-meta#267 stage 5).
- They are also the *least* worth moving: 21 and 806 rows.

**Recommendation: exclude them explicitly and state the exception in the vision.**

### 5.4 `runtime` — excluded for a different reason

Heartbeats are high-rate, ephemeral and TTL-shaped. Appending each to a durable
replicated log is write amplification for data whose value expires in seconds. Its
API is also the largest of the candidates (9 methods including `heartbeat`,
`cleanup_stale`, `update_status`). Either keep it in Postgres or model it as
node-local state that is never folded.

### 5.5 What is genuinely hard, in order

1. **Read-your-writes semantics** (§5.2) — the real design work.
2. **Fold determinism across versions.** If v2 of EHDB changes a relation's shape,
   two nodes on different versions fold the same log into *different* relations
   during a rolling upgrade. The event envelope has versioning discipline; relations
   will need the same, and it is not automatic.
3. **Boot-time rebuild cost** (§4.1 caveat).
4. **Losing ad-hoc SQL.** Operators query these tables during incidents — tonight
   included. A typed get/put/filter API is not a substitute for `psql` when
   something is wrong. **Mitigation should be designed in**: a read-only debug
   endpoint that can dump a relation, or keep a Postgres mirror for humans.

---

## 6. Sequencing — unchanged

```
#307 recovery serves            ← PREREQUISITE
   └── projection tier proven with real comparator coverage
          └── relation-fold materialiser (this RFC), shadowed
                 └── catalog as the first relation
                        └── (projection second — it is already a fold)
                               └── credential / keychain / runtime: EXCLUDED
```

This design rests entirely on "deterministic folds of an ordered log produce
agreeing local state". Today the projection recovery fold **serves nothing** — every
read is `spine_refused`, comparator coverage is zero. **You cannot build relations on
a fold whose correctness you cannot currently measure.**

That sharpens #307 again: **option 3 (accept in-flight-only recovery) forecloses
this design**, because there would be no working fold to materialise from. Option 2
yields the measurement infrastructure this needs.

---

## 7. Summary

- **No SQL, no dialect, no parser.** Rev 1's SQLite recommendation is withdrawn —
  without a query language its query engine has no purpose.
- **Two relations, ~a dozen operations**, is the real initial scope.
- **Build on the existing `ehdb-l0` tier primitives** — it already describes itself
  as "noetl-internal only (fixed datasets)", and `StoreTier` is already the
  code-defined registry the owner's "new relation = new EHDB version" implies. Zero
  new dependencies.
- **Fold-based distribution holds for reads**, and yields the no-migration property:
  a new version folds the existing log into the new relation on boot.
- **Remaining hard parts:** read-your-writes, cross-version fold determinism during
  rolling upgrades, boot rebuild cost, and losing `psql` for incident work.
- **Excluded and stated:** credentials/keychain, runtime, result_store.

## 8. Not done

No code, no dependency, no prod change. Parked pending the owner: the
noetl/ai-meta#307 option choice, the weak-credential rotation
(`playbooks/secret-manager/ROTATE-WEAK-DB-CREDENTIALS.md`), and the dead-data
cleanup (`outbox` 247 MB dead since 2026-06-11; `projection` 0 rows).
