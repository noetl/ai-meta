# Dead-data cleanup — archive before drop, reversibly

**Status: staged, nothing executed.** Every destructive step below is owner-run
and every one of them is preceded by an archive that has been proven to restore.

Tracks [noetl/ai-meta#308](https://github.com/noetl/ai-meta/issues/308).

## The rule this follows

**No blind drop.** A table is archived to a copy, the copy is verified to match
row-for-row, and only then is the original dropped. The restore command is
written down *before* the drop, not derived afterwards.

## 0. Survey — read-only, run this first

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
TOK=$(kubectl --context "$CTX" -n noetl get secret noetl-internal-api-token \
      -o jsonpath='{.data.token}' | base64 -d)

kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  sh -c "wget -qO- -T120 --header='Authorization: Bearer $TOK' \
    'http://127.0.0.1:8082/api/admin/dead-data/report'"
```

Counts and sizes only; no row contents leave the database. ⚠ Deliberately **not**
`POST /api/postgres/execute` — that endpoint is unauthenticated and unrestricted
([#312](https://github.com/noetl/ai-meta/issues/312)), and a cleanup that started
by reaching for it would be using the thing this work should make unnecessary.

### What the three tables actually are

| table | status | evidence |
| :-- | :-- | :-- |
| `noetl.outbox` | **candidate.** Dead since 2026-06-11; the Python publisher that drained it was retired. | ⚠ `live_rows` in the report is the count of **unpublished** rows. **Non-zero ⇒ it is not dead. Stop.** |
| `noetl.projection` | **candidate.** 0 rows, no Rust writer ([#265](https://github.com/noetl/ai-meta/issues/265)). | ⚠⚠ The live store is `noetl.projection_snapshot`. **They are different tables and the names are one character apart.** Dropping the wrong one destroys the projection tier's data. |
| `noetl.execution` | **NOT a candidate — survey only.** | [#235](https://github.com/noetl/ai-meta/issues/235) says its `status` column is frozen, which is a claim about a *column*, not about the table being unused. Do not drop it on that basis. |

## 1. Rehearse the archive path — proves restore is real

```bash
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  sh -c "wget -qO- -T60 --header='Authorization: Bearer $TOK' --post-data='' \
    'http://127.0.0.1:8082/api/admin/dead-data/rehearse'"
```

Creates a scratch table, writes **one synthetic row**, reads it back, compares
it byte-for-byte, drops the scratch table. It touches **no live row**.

**Require `"round_trip_verified": true` before going further.** Without it,
"we will archive first" is a plan whose first step has never been run — and the
server's role is known to lack ownership on some tables (`must be owner of
table event` appears in every boot log), so whether it can create and drop an
archive table is a real question, not a formality.

If it fails on `create_archive_table`, the role cannot create tables in `noetl`.
**Stop** — the archive must then be a `pg_dump` to object storage instead, and
that is a different runbook.

## 2. Archive — a copy, verified, before anything is dropped

`CREATE TABLE ... AS SELECT` rather than a rename, so the original is untouched
while the copy is verified. A rename is reversible too, but it makes the
original unavailable during the window between rename and verification — and
that window is exactly when someone discovers the table was not dead.

```sql
-- one table at a time; substitute <T> = outbox | projection
CREATE TABLE noetl.archive_<T>_20260829 AS TABLE noetl.<T>;

-- the gate: the copy must match, and both counts must be non-zero for outbox
SELECT (SELECT COUNT(*) FROM noetl.<T>)                    AS original,
       (SELECT COUNT(*) FROM noetl.archive_<T>_20260829)   AS archived;
```

⚠ **Do not proceed unless `original = archived`.** For `noetl.projection` both
are expected to be **0**, which is the one case where a zero is the right answer
— and it is also the case where the archive proves nothing, so rely on the row
count in step 0 rather than on this comparison.

## 3. Drop — only after step 2's counts match

```sql
DROP TABLE noetl.<T>;
```

## 4. Restore — write this down before you drop, not after

```sql
CREATE TABLE noetl.<T> AS TABLE noetl.archive_<T>_20260829;
```

⚠ **This restores rows, not the schema object.** Indexes, constraints, defaults
and grants are **not** carried by `CREATE TABLE AS`. If `noetl.<T>` had any —
and `outbox` does — restoring the data is not restoring the table. Capture the
DDL first:

```sql
-- run BEFORE the drop and keep the output with the change record
SELECT indexdef FROM pg_indexes WHERE schemaname='noetl' AND tablename='<T>';
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
 WHERE conrelid = 'noetl.<T>'::regclass;
```

That is the honest limit of this runbook's reversibility, and it is why step 2
keeps the original in place until the copy is verified.

## 5. Retention of the archive

Keep `noetl.archive_*_20260829` for at least **30 days**. Dropping the archive is
its own decision with its own change record — not a tidy-up at the end of this
one.

## What is NOT covered

- `noetl.event` — append-only, source of truth, **never** in scope.
- `noetl.execution` — survey only (see the table above).
- Partitioned tables: ⚠ `pg_total_relation_size` on a partitioned **parent**
  returns 0, because the size lives on the partitions. A 0 in the report means
  "ask the partitions", not "empty".
