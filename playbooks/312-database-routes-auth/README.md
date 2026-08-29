# #312 — gating the database routes

## Current state (2026-08-29, prod)

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
