# Catalog read-cutover — serving `get_latest` from the relation

**Status: staged and wired, NOT flipped.** Catalog reads resolve from Postgres.
The relation folds and (under `verify`) compares, and serves nothing.

Requires server ≥ **v3.95.0** (noetl/server#372). Prod is on v3.94.0 at time of
writing, so **step 0 is deploying that** — the flag does not exist before it.

## The ladder

| `NOETL_CATALOG_READ_SOURCE` | behaviour |
| :-- | :-- |
| `postgres` *(default)* | today. One branch, then return. No fold, no relay call, no extra query. |
| `verify` | resolve from Postgres **and** the relation, compare, record — serve **Postgres**. |
| `tier` | serve the relation, falling back to Postgres when it has no answer. |

An unrecognised value resolves to `postgres`, never forward — a typo must not
move catalog resolution onto an unproven path.

## Preconditions

**1. Full coverage.** Already true on prod as of 2026-08-29:

```
GET /api/catalog-log/coverage
  source_rows=1469  folded_entries=1469  fold_missing=0  full_coverage=true
```

⚠ Serving under partial coverage is not a stale read, it is a **wrong** one:
`get_latest` would answer "not found" for a path that exists, and `list_by_kind`
would under-report — which is the failure mode nobody notices. Re-check coverage
immediately before flipping; new registrations land in the log automatically,
but a restore or an out-of-band insert would not.

**2. Digests agree.**

```
GET /api/catalog-log/verify
  compared=1469  mismatched=0  missing_in_source=0  agrees=true
```

**3. `verify` mode run long enough to mean something** (below).

## Step 1 — `verify`, and what to watch

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_CATALOG_READ_SOURCE=verify
kubectl --context "$CTX" -n noetl rollout status deploy/noetl-server-rust --timeout=8m
```

Every execution that resolves by path now also asks the relation and records the
outcome:

```bash
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  wget -qO- -T25 http://127.0.0.1:8082/metrics | grep noetl_catalog_relation_read_total
```

| outcome | meaning | action |
| :-- | :-- | :-- |
| `agree` | relation and Postgres resolve the same version | what you want |
| `disagree` | **different version** — a real fault | **do not flip.** Investigate |
| `fold_missing` | relation lacks the path | coverage gap — re-run the backfill |
| `source_missing` | relation has it, Postgres does not | the log claims a registration the catalog retired |
| `fold_unavailable` | the fold could not be produced | the tier is unreachable — **not** an empty relation |

⚠ Require `agree` to dominate on a **meaningful denominator**. Prod resolves by
path on every execution, so this accumulates quickly; a handful of samples is not
evidence.

⚠ The relation is **cached** (`NOETL_CATALOG_READ_CACHE_SECS`, default 60). A
`disagree` immediately after a registration may be the cache, not a fault —
re-check after the TTL before concluding anything.

## Step 2 — the flip, and the thing it accepts

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_CATALOG_READ_SOURCE=tier
kubectl --context "$CTX" -n noetl rollout status deploy/noetl-server-rust --timeout=8m
```

⚠⚠ **Read-your-writes.** The relation is a cached fold, so it is stale by
construction for up to the TTL. `register` immediately followed by `execute` on
the same path can resolve the **previous** version — and that looks exactly like
a successful run. The RFC's remedy is a read barrier (`put` returns its
sequence; `execute` passes `min_catalog_sequence`); **that is not built.** Until
it is, flipping to `tier` accepts this window.

Lowering the TTL narrows it but does not close it, and costs a fold per interval.

## Verify after the flip

```bash
# resolution still works, end to end
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  sh -c "wget -qO- -T60 --header='Authorization: Bearer $TOK' \
    --header='Content-Type: application/json' --post-data='{\"path\":\"tests/e2e_probe\"}' \
    'http://127.0.0.1:8082/api/execute'"
```

Expect **COMPLETED, 14 events**. Then confirm `catalog_relation_read_total` shows
no `disagree` and no `fold_missing` accumulating, and that `/api/catalog/list`
and `noetl catalog get` still answer.

## Rollback — one command

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_CATALOG_READ_SOURCE=postgres
```

No schema change, no data migration, `noetl.catalog` untouched throughout — the
relation is a derived read model and nothing writes through it. Roll back on any
`disagree`, or on `fold_unavailable` that does not clear.

## What this does not change

Event log stays **primary**. `NOETL_EHDB_PROJECTION_READ_SOURCE` stays `wal`.
`NOETL_EHDB_RECOVERY_SOURCE` stays wherever it is — the #307 serve-flip is a
**separate** decision with its own runbook.

## Non-prod evidence

Kind-proven: the relation's five reads, archive/restore applied as events in
sequence order (so liveness is derived, not stored), backfill to full coverage,
and idempotence. Mutation-proven in both directions, including that `verify`
cannot serve and that resolution still returns the incumbent tuple — a structural
guard fails the build if the cutover is taken by accident in a refactor.
