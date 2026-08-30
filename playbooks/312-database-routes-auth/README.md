# #312 — gating the database routes

## Current state (2026-08-29, prod) — the write hole is CLOSED

```
server                                v3.96.0
NOETL_DATABASE_ROUTES_AUTH            disable_execute   <- LIVE, closes the write hole
NOETL_INTERNAL_AUTH_MODE              (unset -> shadow) <- deliberately NOT enforce
```

### What actually closed it

`disable_execute`, **not** `gate_all`. The handler refuses before the SQL is
looked at, regardless of the gate's mode — which is the whole reason it works
while `gate_all` did not.

Verified unauthenticated **from another pod** (the worker), which is the real
threat model:

```
POST /api/postgres/execute  {}                              -> 422
POST /api/postgres/execute  {"query":"SELECT 1","schema":"noetl"} -> 422
body (both): {"error":"/api/postgres/execute is disabled by
              NOETL_DATABASE_ROUTES_AUTH=disable_execute (noetl/ai-meta#312)"}
```

⚠ The **status alone proves nothing** — 422 was also the pre-existing
"no query supplied" response. The body is the evidence, and the fact that a
*well-formed* `SELECT 1` gets the identical refusal is what shows the query is
never reached.

### ⚠ `noetl query` is disabled on prod

`noetl query "<SQL>"` posts to this endpoint, so it now fails:

```
$ noetl query "SELECT 1"
Failed to execute query: 422 - {"error":"/api/postgres/execute is disabled ..."}
```

Immediate, non-zero exit, no retry loop, no hang — and the message names the flag
and the issue, so the next person to hit it is not left guessing.

**This is a deliberate removal pending a properly-authenticated reintroduction.**
The command was arbitrary SQL over an unauthenticated endpoint against the
database holding `noetl.event`; reinstating it needs an auth story, not just the
flag turned back. Options: route it through the gateway (already
session-authenticated) rather than direct; have the CLI send
`NOETL_INTERNAL_API_TOKEN` and pair it with `gate_execute` + `enforce`; or replace
it with typed read endpoints of the kind the dead-data survey uses.

It still works against any server that does not set the flag, so local and kind
workflows are unaffected.

### Still open, deliberately

`GET /api/db/validate` remains unauthenticated and returns the **full production
schema listing (58 tables)**. Lower severity than unauthenticated writes and left
as-is: closing it needs either the global `enforce` flip or a code change.

## Prior state, for the record

## Prior state (before disable_execute)

```
server                                v3.96.0
NOETL_DATABASE_ROUTES_AUTH            gate_all     <- LIVE
NOETL_INTERNAL_AUTH_MODE              (unset)      <- defaults to SHADOW
```

## ⚠⚠ `gate_all` alone does NOT close #312

The layer is attached. It rejects nothing, because the gate's mode is global and
prod runs it in **shadow**.

Measured on prod immediately after the flip, from a fresh process at zero:

```
unauthenticated GET  /api/db/validate        -> HTTP 200 OK      (still open)
unauthenticated POST /api/postgres/execute   -> HTTP 422         (reaches the handler)

noetl_internal_auth_total{group="internal",mode="shadow",outcome="missing"}  2
```

The counter moved by **exactly 2** for those 2 probes: the gate *saw* both,
classified both as `missing`, and let both through. That is precisely what
shadow means — and it is why "gate_all is live" must not be reported as
"#312 is fixed".

`auth_gate::gate` reads one **global** `mode()`; the `group` argument is only a
metric label (`src/auth_gate.rs:171-186`). There is no per-group enforcement, so
the database routes cannot be enforced on their own.

## What actually closes it

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_INTERNAL_AUTH_MODE=enforce
```

⚠ **This enforces for all 17 gated route groups at once**, not just the database
routes: credentials, keychain, internal, projection, cross-region,
wallet-rotate, secret-audit, container-callback, object-store, cell, result-tier,
sink-state, ingress, ehdb-equivalence, registry. Any legitimate caller that does
not send `NOETL_INTERNAL_API_TOKEN` starts receiving 403.

**That is a materially wider decision than gating one router, and it is the
owner's.**

### The evidence that informs it

Shadow mode is already recording what enforce would do:

```
noetl_internal_auth_total{group="internal",mode="shadow",outcome="valid"}    16
noetl_internal_auth_total{group="internal",mode="shadow",outcome="missing"}   4
```

⚠ Read this carefully rather than as a ratio. Of those 4 `missing`, **2 are my
own probes**. The rest is a small sample over minutes on a freshly-restarted
process — nowhere near enough to conclude enforce is safe.

**Before enforcing, let shadow run long enough to cover the slow paths** — the
hourly `scheduled_cleanup` CronJob, the 300 s parity sampler, any operator
tooling — and require `missing` to be attributable. A single unattributed
`missing` is a caller that will break.

Note also that all three groups report under `group="internal"` today, so the
counter cannot say *which* router a `missing` came from. Attribution needs either
a per-router label or a log correlation.

## Rollback — one command each, independent

```bash
# back to open (today's behaviour before this change)
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_DATABASE_ROUTES_AUTH-

# if enforce is ever enabled and needs reverting
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_INTERNAL_AUTH_MODE-
```

Both are env-only; no schema change, no data migration. Unsetting
`NOETL_DATABASE_ROUTES_AUTH` returns the router to `open` and is a safe resting
state — it is the configuration that ran before v3.96.0.

## The other three options, still reachable

`gate_execute`, `readonly_execute` and `disable_execute` are the same flag.
⚠ `gate_execute` has the same shadow caveat. **`disable_execute` does not** — it
refuses in the handler regardless of the gate mode, so it is the only option that
closes `/api/postgres/execute` without touching global enforcement.

That may make `disable_execute` the better first move: its only callers are
developer test scripts, and it needs no decision about the other 16 groups.
