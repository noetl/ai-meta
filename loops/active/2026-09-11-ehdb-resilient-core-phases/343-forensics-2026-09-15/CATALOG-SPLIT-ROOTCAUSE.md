# Catalog split — root cause found, fix is one env var (BLOCKED on permission)

Follows `RECOVERY-2026-09-15.md`. Diagnosis is complete and read-only.

## Not two replicas

`svc/noetl` has **exactly one** endpoint: `10.119.0.12` → `noetl-server-rust-embedded-0`
(the `noetl-server-rust` Deployment is 0/0 and vestigial). The alternating reads
are **one server resolving from two different stores**, not load balancing.

## Root cause

Prod server env:

```
NOETL_CATALOG_READ_SOURCE=verify      <- the read ladder
NOETL_CATALOG_LOG=shadow
NOETL_CATALOG_SNAPSHOT=digest
```

`repos/noetl-server-wiki/deployment-specification.md:362` defines the ladder, and
`playbooks/catalog-read-cutover/README.md` states the precondition that is now
violated:

> ⚠ Serving under partial coverage is not a stale read, it is a **wrong** one:
> `get_latest` would answer "not found" for a path that exists, and
> `list_by_kind` would under-report — which is the failure mode nobody notices.

**Both halves of that prediction are observed on prod right now.**

## Evidence

`GET /api/catalog-log/coverage`:

```
source_rows=2533  folded_entries=2528  fold_missing=5  full_coverage=FALSE
```

`source_rows=2533` is Postgres and **exactly matches** the catalog read that
contains this session's four registrations. The relation fold is **5 entries
short**, and 4 of those are the registrations (duffel v7, hotelbeds v6,
hotel-cards v4, flights-details v1).

The two datasets are genuinely different, not a truncated read — they use
different *kind vocabularies*:

| read | entries | distinct paths | kinds |
|---|---|---|---|
| A | 2533 | 341 | `playbook`, `subscription` (normalized) |
| B | 1370 | 219 | `Playbook`, `mcp`, `playbook` (legacy mixed-case) |

B carries the pre-normalisation kind strings, and its version counters are an
independent history (duffel v19 vs A's v7; itinerary-planner v113 vs A's v17).

**Consequences now live on prod:**

- `POST /api/execute` → `404 "Playbook not found: muno/playbooks/flights-details"`
  for a path that IS registered. This is `get_latest` answering "not found" for a
  path that exists — the documented symptom, verbatim.
- `GET /api/executions` under-reports: executions that demonstrably ran
  (`test/simple_loop` COMPLETED) vanish from later reads.

⚠ **Not a valid existence test:** `GET /api/executions/{id}/cancel` returns 405
for ANY id — it is "GET not allowed on this route", not "the execution exists".
This session initially misread it as existence. Use the detail endpoint.

## The fix — documented, reversible, one env var

`playbooks/catalog-read-cutover/README.md` line 112 gives the rollback:

```bash
kubectl -n noetl set env sts/noetl-server-rust-embedded \
  -c noetl-server NOETL_CATALOG_READ_SOURCE=postgres
kubectl -n noetl rollout status sts/noetl-server-rust-embedded --timeout=5m
```

Per the ladder, `postgres` is "today's default. One branch, then return. No fold,
no relay call, no extra query." It changes **no data** — it only stops resolving
catalog reads through an incomplete relation. Reverting is the same command with
`verify`.

⚠ Note the playbook targets `deploy/noetl-server-rust`, which is now **0/0 and
vestigial**. Prod runs `sts/noetl-server-rust-embedded`. The playbook needs that
correction.

## Status: BLOCKED

The agent session could not apply it — `kubectl set env` on a prod workload is
refused by the session's permission sandbox. Diagnosis complete; the mutation
needs an operator (or a permission grant).

## Longer-term

`full_coverage=false` should gate the ladder in code: serving `get_latest` from a
relation with `fold_missing>0` produces confidently wrong "not found" answers.
The playbook already says to re-check coverage immediately before flipping, but
nothing enforces it at runtime. Worth an issue against noetl/server.
