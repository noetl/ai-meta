# RFC — step 3: the catalog fold relation (get / put / filter on `StoreTier::Catalog`)

**Status:** design. Steps 1 and 2 are built and kind-proven; this is the read
side. Nothing here is deployed, and the read cutover is explicitly **not** part
of it.
**Date:** 2026-08-29
**Predecessors:** `docs/rfc/ehdb-catalog-relation.md` (the model and the grounding),
`docs/rfc/ehdb-embedded-relational-projections.md` (why a relation is a fold).

## 0. What steps 1 and 2 established, and what is left

| | built | proven |
| :-- | :-- | :-- |
| **1** execution-start snapshot | server v3.93.0 | a later registration cannot alter a finished execution's snapshot; digests reproduce the exact bytes |
| **2** registration log | worker#289 + server#371 | `agrees=true`, 4/4 compared, 0 mismatched; two negative controls |
| **3** the relation | *this document* | — |

Step 2 gave the catalog a log. Step 3 makes that log answerable: a typed
`get`/`put`/filter API served from a fold, verified against Postgres, and
serving nothing until someone decides otherwise.

## 1. The API, and its true size

Derived from the functions already in `src/db/queries/catalog.rs` — this is the
surface in use, not an invented one.

```rust
pub struct CatalogRelation { /* folded state */ }

impl CatalogRelation {
    // reads
    fn get_latest(&self, path: &str)                -> Option<&Entry>;  // non-archived
    fn get(&self, path: &str, version: i32)         -> Option<&Entry>;
    fn get_by_id(&self, catalog_id: i64)            -> Option<&Entry>;
    fn list_versions(&self, path: &str)             -> Vec<&Entry>;      // ascending
    fn list_by_kind(&self, kind: Option<&str>)      -> Vec<&Entry>;

    // writes — through the log, never against the fold
    fn put(entry: NewEntry)  -> Result<Written, Refusal>;   // = register
    fn archive(path, version: Option<i32>) -> Result<Written, Refusal>;
    fn restore(path, version: Option<i32>) -> Result<Written, Refusal>;
}

pub struct Written { pub catalog_id: i64, pub version: i32, pub sequence: u64 }
```

Five reads, three writes. That is the whole relation.

`get_latest` is the only one with a subtlety: **highest non-archived version**.
In a key-ordered store that is the last live entry in the `path` prefix — free,
not a `MAX()`.

### 1.1 Indexes

`path` primary (with `version`), `kind` secondary, an `archived` flag. No joins,
no aggregates.

### 1.2 The global `kind`

Carried as an indexed field over the closed set in `noetl.resource` —
`playbook`, `credential`, `mcp`, `agent`, `memory`, `subscription`. One relation
holds every item type; `list_by_kind` is the filter, not a table per kind.

⚠ **`credential` rows carry reference metadata only.** The relation must refuse
to carry credential *content*, and that refusal has to be enforced rather than
assumed — a fold replicates to every node, so a mistake here is not local.

### 1.3 Version width

`noetl.catalog.version` is Postgres `smallint`; the relation should use `i32`.
32,767 versions per path is a real ceiling and an agent-driven registration loop
is what finds it. Widening in the relation costs nothing and does not require
touching the source column.

## 2. ⭐ archive / restore are the interesting part

Every other operation is an append. `archive` and `restore` are the only
mutations in an otherwise immutable source — the sole `UPDATE noetl.catalog` in
the codebase sets or clears `archived_at`.

In a fold they **must become events**, not in-place edits:

```
catalog.registered  { path, version, kind, content, content_sha256 }
catalog.archived    { path, version? }      // version absent = every version
catalog.restored    { path, version? }
```

The fold applies them in `global_sequence` order, so archived-ness is derived
state rather than a stored flag. Two properties fall out that a stored flag does
not give:

- **The history is inspectable.** "When was this archived, and by which
  operation?" is answerable; today it is a timestamp with no actor and no
  ordering against anything else.
- **Re-archiving is idempotent by construction** — applying `archived` twice
  yields the same state, which the current `WHERE archived_at IS NULL` predicate
  achieves only because it happens to be written that way.

⚠ This is also where the fold can diverge from the source most easily, because
it is the one place the source is not append-only. The comparator must check
archived-ness explicitly, not just content digests — a fold that agrees on every
digest while disagreeing on which entries are live would pass a naive check and
resolve `get_latest` to the wrong version.

## 3. Fold sources — two, and they cover different things

| source | covers | carries |
| :-- | :-- | :-- |
| `catalog.registered` events (step 2) | registrations **after** the cutover | full content + digest |
| `execution.catalog_snapshot` events (step 1) | anything **executed**, including before | identity + digest; content only in `full` mode |

The union is strictly better than either. A path registered before step 2 but
executed since is present in the relation via its snapshots — identity, version
and digest — even though no registration event exists for it. It just cannot be
*reconstructed* from the log unless snapshots ran in `full` mode.

### 3.1 ⚠ The backfill problem is the real blocker for serving

2,518 catalog rows predate step 2 and have no registration event. Until that is
addressed the relation's coverage is a **strict subset** of the catalog, so:

- `get(path, version)` may miss an entry that exists → a fold-served read would
  be **wrong**, not merely stale.
- `list_by_kind` would under-report, and under-reporting is the failure mode
  nobody notices.

Three options, and the choice is a genuine decision:

1. **Backfill synthetic `catalog.registered` events** from the existing rows,
   marked as backfilled so provenance stays honest. Complete coverage; ~17.4 MB
   of content into the log.
2. **Digest-only backfill** — identity without content. Enough for `get_latest`,
   `list_*` and verification; not enough to reconstruct an item.
3. **Accept partial coverage and never serve `list_*`** from the fold, only
   point reads for keys the fold has.

**Recommendation: (2), then (1) if the log is to become self-sufficient.** But
serving must not be enabled under (3) — a relation that silently answers "not
found" for an entry that exists is worse than one that refuses.

## 4. Read-your-writes

`register` then immediately `execute` is the normal authoring loop.

`put` returns its `sequence`; `execute` accepts an optional
`min_catalog_sequence` and refuses (or waits) until the local fold has reached
it. The contract is explicit at the API rather than hidden behind a sleep.

**What must not happen is a silent stale read**, because the failure mode is
"the execution ran the previous version" — which looks exactly like a successful
run. That is the same shape as noetl/ai-meta#307, where the failure looked like
health.

## 5. Rollout — verify before serve, and the cutover is not ours

Mirroring the ladder that worked for #307:

| `NOETL_CATALOG_READ_SOURCE` | behaviour |
| :-- | :-- |
| `postgres` *(default)* | today, byte-identical |
| `verify` | answer from Postgres **and** the fold, compare, record agreement — serve the Postgres answer |
| `tier` | serve the fold |

`verify` is the whole of step 3's deployment. It produces the coverage and
agreement evidence, and it serves nothing. **The flip to `tier` is a separate
owner decision**, exactly as the #307 serve-flip is, and for the same reason:
agreement measured over a window is not agreement guaranteed.

### 5.1 The metric that must exist

`noetl_catalog_relation_read_total{operation, outcome}` where `operation` is one
of the five reads and `outcome` ∈ `{agree, disagree, fold_missing, source_missing}`.
Every pair pinned at 0 — the reading of interest is a zero, and an absent series
is indistinguishable from one.

`fold_missing` is the label the backfill problem shows up on, and it must be
distinguishable from `disagree`: "the fold does not have this yet" and "the fold
has something different" want opposite responses.

## 6. What is genuinely hard

1. **Backfill** (§3.1) — a decision, not an implementation detail.
2. **archive/restore as events** (§2), and a comparator that checks liveness and
   not only digests.
3. **Read-your-writes** (§4).
4. **Losing ad-hoc SQL.** Operators query `noetl.catalog` during incidents; a
   typed API is not a substitute for `psql`. Keep Postgres readable, and treat
   any plan that removes it as needing its own replacement first.

## 7. Boundaries

Event-log primary unchanged. Credentials excluded (§1.2). Fail-closed: a fold
that cannot answer refuses rather than reporting empty — the distinction step 2's
negative control was built around. Default-off. No prod deploy while the platform
is down (noetl/ai-meta#311).
