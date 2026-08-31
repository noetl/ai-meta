# Event-history archive + the parked truncate

**Status 2026-08-31: archive COMPLETE and verified. The truncate is PARKED —
owner-run, not executed.** Nothing has been deleted.

## The archive

`gs://shastaratech-noetl-prod-eventlog-archive-20260831` — private:
uniform bucket-level access **enabled and locked** (until 2026-11-29),
public access prevention **enforced**, **0** public bindings. It contains
credentials and an Auth0 session-validation execution, so that posture is
load-bearing, not decorative.

| object | size | verified by |
| :-- | --: | :-- |
| `postgres/noetl-full-20260831.sql.gz` | **6.95 GB** | content: **1,020,651** `noetl.event*` rows across all three partitions; `noetl.catalog` = **1,469**, which cross-checks the live catalog exactly; `noetl.credential` = 21 |
| `tier/eventbus/eventlog.jsonl` | 257,983,993 B | MD5 `2b8b6300d092…` matches source |
| `tier/eventbus/catalog.jsonl` | 175,925,989 B | MD5 `f55f0049119f…` matches source |
| `tier/eventbus/projection.jsonl` | 3,082,682 B | MD5 `b713b74ae31e…` matches source |
| ~~`postgres/noetl-history-20260831.sql.gz`~~ | 1,974 B | ⚠ **schema only, 0 rows — discard** |

### ⚠ The first export silently produced nothing

It reported `DONE` with **no error** and wrote 1,974 bytes containing **0 COPY
and 0 INSERT** statements. `noetl.event` is `PARTITION BY RANGE (execution_id)`,
so `--table=noetl.event` dumped the parent's definition while every row lives in
`event_default` / `event_2026_q2` / `event_2026_q3`, which the filter never
matched. Trusting the exit status would have deleted a million rows against an
empty archive. The re-run is a full-database export.

**A `DONE` from `gcloud sql export` is not evidence that data was exported.**
Count rows inside the dump.

### Test-restore was NOT performed

The owner accepted content verification instead. It could not be done from this
session: `/api/postgres/execute` is disabled by config
(`NOETL_DATABASE_ROUTES_AUTH=disable_execute`, mitigating
[#312](https://github.com/noetl/ai-meta/issues/312)), and `psql` in the pgbouncer
pod has no password without reading a Secret Manager value. `gcloud sql import`
can restore, but nothing available here can then COUNT in the scratch database —
so success could have been asserted but not demonstrated.

### Restore

```bash
gcloud sql import sql noetl-shared-pg \
  gs://shastaratech-noetl-prod-eventlog-archive-20260831/postgres/noetl-full-20260831.sql.gz \
  --database=noetl --project=shastaratech-noetl-prod
```

⚠ This is a **full-database** restore: it also rewrites `noetl.catalog` and
`noetl.credential` to their 2026-08-31 state.

Tier restore:

```bash
gcloud storage cat gs://shastaratech-noetl-prod-eventlog-archive-20260831/tier/eventbus/eventlog.jsonl \
  | kubectl exec -i -n noetl noetl-cmdbus-writer-0 -- sh -c 'cat > /data/eventbus/ehdb-tier/eventlog.jsonl'
```

## The parked truncate — owner-run

Not executable from this session for the same reason the test-restore was not:
there is no SQL write path. `/api/admin/dead-data/*` offers only `report` and
`rehearse`; `/api/internal/cleanup/purge` is retention-age-based, not a full
delete; the Cloud SQL API has no truncate.

**No foreign key blocks it.** Of the 13 FKs in the schema, **zero reference**
`noetl.event`, `projection`, `projection_snapshot` or `outbox`. The dependency
runs the other way — `noetl.event.catalog_id REFERENCES noetl.catalog(catalog_id)`
— so the catalog being preserved is the *parent* and nothing dangles.
`TRUNCATE` on the partitioned parent cascades to all partitions, so no
per-partition ordering is needed.

```sql
TRUNCATE noetl.outbox;
TRUNCATE noetl.projection;             -- expected 0 rows (dead table, #265)
TRUNCATE noetl.projection_snapshot;    -- the LIVE projection store
TRUNCATE noetl.event;                  -- cascades to all three partitions

SELECT (SELECT count(*) FROM noetl.event)               AS events,
       (SELECT count(*) FROM noetl.outbox)              AS outbox,
       (SELECT count(*) FROM noetl.projection_snapshot) AS projsnap,
       (SELECT count(*) FROM noetl.catalog)             AS catalog,     -- expect 1469
       (SELECT count(*) FROM noetl.credential)          AS credential;  -- expect 21
```

⚠⚠ **`noetl.projection` and `noetl.projection_snapshot` are different tables and
the live one is the longer name.** `projection` is dead (0 rows, no Rust writer,
[#265](https://github.com/noetl/ai-meta/issues/265)); `projection_snapshot` is
the store the projection tier actually uses. Truncating the wrong one is a
silent no-op; assuming they are the same is how the real store gets missed.

⚠ **Do NOT `TRUNCATE noetl.command`** — 14.8 GB command queue, out of scope, and
wiping it strands in-flight executions.

⚠ `system/scheduled_cleanup` is an hourly cron, so "empty" is a momentary state.

## What the history actually contains

Measured from the dump, bucketed on the real `created_at` column:

* **1,020,651 events spanning 2026-02-26 → 2026-08-31 (~187 days).**
* **74.7% of all events fall on 12 days**, dominated by 2026-05-07 (204,557) and
  2026-05-18 (138,697) — load-test or backfill spikes. Ordinary days are
  300–1,400 events.
* Of ~1,800 recent executions, **806 are business/provider traffic**
  (`mcp/firestore` 415, `itinerary-planner` 297, HotelBeds/Duffel/Places ~80,
  plus one `auth0_validate_session`), the rest scaffolding.

⚠ Earlier figures of "19 days" and "78 days" were both wrong, and wrong the same
way: they were read off the **tier**, which is a copy with a later start date.
See `mirror-coverage-2026-08-31.md`.
