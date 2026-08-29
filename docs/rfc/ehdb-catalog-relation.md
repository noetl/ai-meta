# RFC — the catalog relation: a global, versioned, immutable item registry in EHDB

**Status:** design. Step 1 (the execution-start snapshot) is built; the fold into
the tier is deliberately **not**.
**Date:** 2026-08-29
**Companions:** `docs/rfc/ehdb-embedded-relational-projections.md` (the relation
model), `docs/rfc/postgres-to-ehdb-internal-data.md` (why internal state moves).

This is the first concrete relation of the embedded-EHDB model, and it is written
against the code rather than the docs — which matters, because three of the things
the docs imply are not what the code does.

---

## 0. Three grounding corrections, stated first because they move the design

### 0.1 ⚠⚠ `playbook.initialized` is never emitted

The status-transition matrix names `playbook.initialized` as the PENDING→RUNNING
owner signal, and it was the natural hook for the snapshot. **It does not exist in
the Rust path.** Five sites *read* it:

```
src/handlers/nonconvergence_sweep.rs:434   src/services/execution.rs:461, :612
src/handlers/container_callback.rs:317     src/services/credential.rs:192
```

…all as `event_type IN ('playbook.initialized', 'playbook_started', …)`
compatibility predicates. Nothing writes it. The event a real execution actually
starts with is **`playbook_started`**, confirmed by reading the event stream of a
live execution:

```
 1. playbook_started   node=tests/227/slow_step  status=STARTED
                       context keys = [catalog_id, execution_id, path, workload]
 2. command.issued     …
```

So the hook is `playbook_started`, and the snapshot rides **beside** it.

### 0.2 ⚠⚠ Catalog registration is not event-sourced at all

`POST /api/catalog/register` performs a direct `INSERT INTO noetl.catalog`. There
is no emit site in `src/services/catalog.rs` or `src/handlers/catalog.rs`.

**This is the single biggest gap for the relation.** A relation is a fold of a log;
there is no catalog log. Until registration emits events, a catalog relation can
only be built by scanning the Postgres table — which is the copy, not the log, and
therefore not a relation in this model's sense at all.

It also inverts the value of step 1: the execution-start snapshot events are, today,
the **only** event-sourced record of catalog content that exists.

### 0.3 The catalog is already global, and already immutable

Requirements 1 and 2 are largely satisfied by the existing schema, which is worth
knowing before proposing to add them:

```sql
CREATE TABLE noetl.catalog (
    catalog_id BIGINT PRIMARY KEY,
    path     TEXT        NOT NULL,
    version  SMALLSERIAL NOT NULL,
    kind     VARCHAR     NOT NULL REFERENCES noetl.resource(name),
    content  TEXT, layout JSONB, payload JSONB, meta JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (path, version)
);
```

- **`kind` is a foreign key into `noetl.resource`**, whose seeded rows are
  `playbook`, `credential`, `mcp`, `agent`, `memory`, plus `subscription` added by
  `ensure_builtin_kinds`. Each carries `{"executable": bool, "catalog": bool}` in
  `meta`. The global item registry is not a thing to add — it is a thing to carry
  across.
- **Immutability already holds for content.** The only `UPDATE noetl.catalog` in
  the codebase sets or clears `archived_at`; `content`, `layout` and `payload` are
  never updated. So `(path, version)` content is immutable in practice, and
  archival is a separate mutable marker on an otherwise frozen row.

Measured on a live catalog (2,518 entries): kinds are `playbook` 2,489 and
`subscription` 29; largest content **267,388 bytes** (`muno/playbooks/itinerary-planner` v17),
median **3,116 bytes**, total 17.4 MB. Those numbers decide §3.3.

---

## 1. The version model, and its two real limits

`get_next_version` is `SELECT (COALESCE(MAX(version),0)+1) FROM noetl.catalog WHERE path = $1`,
then an INSERT. Read-then-insert, so two concurrent registrations of the same path
compute the same next version.

**That race fails closed**, because `UNIQUE (path, version)` rejects the second
insert. The caller gets an error rather than a silently forked version. Good, and
worth stating explicitly since the shape of the query invites the opposite
conclusion.

⚠ **`version` is `smallint`.** 32,767 versions per path is the hard ceiling. The
busiest real path is at v17; a machine-registered path under an agent loop is the
case that would find it. The relation should carry a wider version type and treat
the `i16` as a Postgres-era artefact rather than reproducing it.

**Resolution semantics**, which the relation must preserve exactly:

| by | resolves to |
| :-- | :-- |
| `path` | highest `version`, **excluding archived** — `ORDER BY version DESC LIMIT 1` with a conditional `archived_at IS NULL` predicate |
| `catalog_id` | that exact row, **including archived** — deliberate, so a historical version can be re-run on purpose |

⚠ The archived predicate is **conditional on the column existing**, because
`archived_at` was added out of band by an operator and the server cannot create it
(the table is owned by another role). Hard-coding it took production down. Any
reimplementation must keep that property or re-learn it.

---

## 2. The relation and its API

Per the relation model: code-defined, versioned with EHDB, no runtime DDL, and a
small typed API rather than a query language. Derived from the existing public
functions in `src/db/queries/catalog.rs` — the API is not invented, it is the one
already in use.

| operation | key / filter | today |
| :-- | :-- | :-- |
| `get_latest(path)` | `path`, highest version, non-archived | `get_catalog_latest` |
| `get(path, version)` | composite key | `get_catalog_by_path_version` |
| `get_by_id(catalog_id)` | surrogate key | `get_catalog_by_id` |
| `list_versions(path)` | by `path`, ordered | `get_catalog_all_versions` |
| `list_by_kind(kind?)` | equality on an indexed field | `list_catalog_entries` |
| `put(entry)` | append a new immutable version | `insert_catalog_entry` |
| `archive(paths)` / `restore(paths)` | set/clear the marker | `archive_/restore_catalog_entries` |
| `delete(paths)` | hard delete | `delete_catalog_entries` |

**Indexes: `path` (primary, with `version`), `kind` (secondary), an `archived`
flag.** No joins, no aggregates: "highest version for a path" is the last entry in
a key-ordered `path` prefix, which is free rather than a `MAX()`.

`put` is the only mutating operation on content, and it only ever appends — which
is why this relation is a good first one. `archive`/`restore` are the awkward pair:
they mutate a row that is otherwise immutable, so in an event-sourced relation they
must become *events* (`catalog.archived`, `catalog.restored`) that the fold applies,
never in-place edits.

### 2.1 The global `kind`

The relation carries `kind` as a first-class indexed field over the closed set in
`noetl.resource`, so it holds playbooks, agents, MCP providers, memory artefacts and
subscriptions in one relation — a single `list_by_kind` rather than a table per
kind. `noetl.resource` itself becomes a second, tiny relation (name → meta), or a
code-defined enum if the set is frozen at release time; the model says a new kind is
a new EHDB version, which argues for the enum.

⚠ **`credential` is a registered kind, and the relation must not carry its
content.** The embedded-relational RFC excludes credentials for reasons that apply
with more force here: event-sourcing a secret makes the plaintext history *be* the
log, and fold-based distribution replicates it to every node. Catalog rows of kind
`credential` hold *reference metadata* rather than secret material, but the relation
should carry the metadata and refuse the content, and that refusal should be
enforced rather than assumed.

### 2.2 Read-your-writes: register-then-run

The sharp edge. `POST /api/catalog/register` immediately followed by
`POST /api/execute` on the same path is the normal authoring loop, and under a
fold-based relation the local fold may not have caught up.

Three options, unchanged from the parent RFC, but here one of them is clearly best:
**`put` returns the write's `global_sequence`, and `execute` may pass a
`min_catalog_sequence`** — a read barrier. It makes the consistency contract
explicit at the API instead of hiding it behind a sleep, and it composes with the
typed API for free.

Blocking until the fold catches up is the fallback; reading through to the log for
the catalog specifically is the escape hatch. What must **not** happen is a silent
stale read, because the failure mode is "the execution ran the previous version" —
which looks exactly like a successful run.

---

## 3. Step 1 — the execution-start snapshot (built)

### 3.1 What it is

At execution start, an immutable event records exactly which catalog item the
execution is running, tied to the `execution_id`:

```
event_type = "execution.catalog_snapshot"
context = {
  catalog_id, path, kind, version,
  content_sha256,            // pins the bytes cryptographically
  content_bytes,             // the size, always, even when content is omitted
  content,                   // present in `full` mode, subject to a cap
  content_included: bool,
  content_omitted_reason,    // set iff content_included == false
  workload_sha256,           // the EFFECTIVE post-merge workload
  snapshot_version: 1
}
```

### 3.2 Why a separate event and not fields on `playbook_started`

Because `playbook_started`'s `context` is **read by the fold**:
`state.rs:508` extracts `workload`, `path` and `version` from it. Adding keys there
risks changing `canonical_state_digest` for every execution — and the #307
equivalence work that just went live on prod compares exactly those digests. A
separate event type cannot do that, and the reason is checked rather than assumed:

`WorkflowState::apply_event` spans `state.rs:499–990` and its match ends in a
`_ => {}` fallback at line 988. **An unrecognised event type is ignored**, so the
snapshot event contributes nothing to the folded state.

⚠ It does contribute to the *event set*: `applied_count` and the fold's `version`
watermark (highest `event_id`) both move. That is harmless for the comparator
because both sources see the same event — the mirror carries it like any other —
but it is a real change to those two numbers and is called out rather than
discovered.

### 3.3 The size decision, which the measurements force

Median content is 3.1 KB and the maximum is 267 KB. `noetl.event` is already ~2.9 GB
on prod. A full-content snapshot on every execution of the itinerary planner adds
267 KB **per run**, of bytes that are identical every time because the catalog row is
immutable.

So the mode is a three-way flag, defaulting to off:

| `NOETL_CATALOG_SNAPSHOT` | behaviour |
| :-- | :-- |
| `off` *(default)* | no snapshot event. Byte-identical to today. |
| `digest` | metadata + `content_sha256` + `content_bytes`. ~250 bytes/execution. The pin is cryptographic and complete; the bytes are recoverable from the immutable catalog row. |
| `full` | as `digest`, plus the content itself, up to `NOETL_CATALOG_SNAPSHOT_MAX_BYTES` (default 1 MiB, above the 267 KB maximum). Over the cap the content is **omitted with a stated reason**, never truncated — a truncated snapshot is a lie about what ran. |

`digest` is the recommended production setting. It satisfies the pinning
requirement completely: `content_sha256` identifies the exact bytes, and a later
catalog change cannot alter a hash already written to an append-only log. `full`
buys self-sufficiency — the log alone reconstructs the item without the catalog —
which matters only against `delete_catalog_entries`, the one hard-delete path.

### 3.4 Ephemeral / agent-mutated versions

Agent playbooks may mutate their own structure. The snapshot is taken **after**
parse and after the workload merge — `content` is the resolved YAML that
`parse_playbook` consumed, and `workload_sha256` covers the *effective* workload
(playbook `workload:` defaults overlaid with the request `payload:`), not the
request alone. So what is recorded is what the execution actually started with,
including a request payload that overrode a default.

⭐ **The elegant consequence, which is the real argument for this design.** Because
the snapshot lands in the immutable append-only event log, the ephemeral-version and
cross-instance-drift problem is solved *by construction*: the log is the ground-truth
record of exactly what ran, and the catalog relation is only a queryable index over
it. A version that existed for one execution and was never registered is still fully
recorded. Nothing has to be retained on the catalog side to make a past execution
explicable.

⚠ Scoped honestly: structure the agent mutates *later, mid-execution* is not in this
snapshot. Those mutations are themselves events, so the log still holds them — but
reconstructing "the structure at step N" is a fold over those events, not a field on
this one. That is a later increment, and it is a fold, which is the point.

---

## 4. What step 2 must do, and why it is not this increment

The relation folds from **catalog-registration events + execution snapshots**. Only
the second exists. Step 2 is therefore:

1. **Make registration emit events** — `catalog.registered`, `catalog.archived`,
   `catalog.restored`, `catalog.deleted` — at the one chokepoint, in the same
   transaction as the row write. Without this there is no log to fold.
2. **Backfill** the existing 2,518 rows as synthetic `catalog.registered` events,
   or accept that the relation only covers post-cutover registrations and say so
   where it is read.
3. **Fold into a `StoreTier::Catalog` variant** with the §2 API, shadowed against
   the Postgres queries with the same comparator discipline #307 established.
4. **Decide `archive`/`restore`** as events, not in-place edits (§2).

Step 1 is a prerequisite for none of these — it is independently valuable, which is
why it ships first and alone.

---

## 5. Boundaries

Event-log primary stays primary. Credentials excluded (§2.1). Fail-closed: a
snapshot failure must never fail the execution. Additive and default-off. No prod
cutover in this increment.

## 6. Related

- `docs/rfc/ehdb-embedded-relational-projections.md` — the relation model this
  instantiates.
- [noetl/ai-meta#307](https://github.com/noetl/ai-meta/issues/307) — the measurable
  fold this rests on; prod is live in `verify`.
- `agents/rules/representation-drift.md` — §0.1 and §0.2 are both instances: a
  documented event nothing emits, and a registry nothing logs.
