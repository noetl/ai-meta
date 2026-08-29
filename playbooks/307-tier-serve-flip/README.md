# #307 — the `tier` serve-flip

**Status: staged, owner-run. NOT executed.** Prod is on `verify`; the fold is
measured and compared and **serves nothing**.

Current state, read from prod 2026-08-29:

```
noetl_server_build_info{version="3.94.0"}                1
noetl_ehdb_recovery_source_info{mode="verify"}           1
noetl_ehdb_projection_read_total{outcome="served_tier"}  0
NOETL_EHDB_PROJECTION_READ_SOURCE = wal   (unchanged)
NOETL_EHDB_RECOVERY_SOURCE        = verify
```

## ⚠ Read this before flipping — what `verify` does NOT prove

The in-path verdict machinery **cannot see tier-vs-Postgres divergence**. By
explicit design it never consults Postgres: it checks the tier against *itself*.
And `wal_projection_state` materialises **then** refolds, so on a divergent tier
it re-materialises from the divergent source and agrees.

Demonstrated in kind: an injected phantom event left `wal_verdict = match` while
the refold endpoint — which does not materialise first — correctly reported
`digest_mismatch`.

Two layers **do** catch it, and neither is in the serving path:

- the continuous **cross-store parity comparator** (`outcome=divergent`,
  `extra_event`), which samples every 300 s over executions settled ≥120 s;
- the **equivalence sweep**, which is an operator action, not continuous.

**So flipping to `tier` accepts that a divergence is caught by sampling and by a
sweep someone runs — not by the read itself.** That is the decision, and it is
the reason this is owner-run.

## Precondition — equivalence coverage on a real denominator

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
TOK=$(kubectl --context "$CTX" -n noetl get secret noetl-internal-api-token \
      -o jsonpath='{.data.token}' | base64 -d)

kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  sh -c "wget -qO- -T300 --header='Authorization: Bearer $TOK' \
    'http://127.0.0.1:8082/api/ehdb/projection-recovery/equivalence?limit=50'"
```

Require **`"equivalent": true` with `agreed` well above zero**. `agreed > 0` is
enforced by the endpoint because an empty sweep has zero disagreements and would
otherwise read as a pass — but a denominator of 1 is not evidence either.

⚠ Expect `tier_refusals: {payload_too_old: N}` to shrink over time and never
reach zero for old executions: records written before the `context` fix cannot
be folded, by design. **The sweep attests only to executions completed after
server v3.93.0.** Judge `agreed`, not the absence of refusals.

## Flip

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_EHDB_RECOVERY_SOURCE=tier
kubectl --context "$CTX" -n noetl rollout status deploy/noetl-server-rust --timeout=8m
```

## Verify after

```bash
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  wget -qO- -T25 http://127.0.0.1:8082/metrics | grep -E \
  'recovery_source_info|recovery_fold_total|served_tier|crossstore_divergence'
```

Expect `recovery_source_info{mode="tier"} 1`, `recovery_fold_total{source="tier",
outcome="folded"}` climbing, **`served_tier` moving off 0** — that is the
observable that distinguishes this flip from the `verify` one — and
`crossstore_divergence_total` **staying at 0**.

⚠ Counters are per-process and reset on the roll. A zero immediately after is
backoff, not a regression; the parity sampler ticks every 300 s.

Then an e2e:

```bash
kubectl --context "$CTX" -n noetl exec deploy/noetl-server-rust -c noetl-server -- \
  sh -c "wget -qO- -T60 --header='Authorization: Bearer $TOK' \
    --header='Content-Type: application/json' --post-data='{\"path\":\"tests/e2e_probe\"}' \
    'http://127.0.0.1:8082/api/execute'"
```

Expect **COMPLETED, 14 events** (13 + the catalog snapshot, since
`NOETL_CATALOG_SNAPSHOT=digest` is live).

## Rollback — one command

```bash
kubectl --context "$CTX" -n noetl set env deploy/noetl-server-rust \
  -c noetl-server NOETL_EHDB_RECOVERY_SOURCE=verify
```

No schema change, no data migration, the Postgres fallback is untouched. Roll
back on any `crossstore_divergence_total` movement or any non-self-healing
refusal.

## Unchanged by this flip

Event log stays **primary**. `NOETL_EHDB_PROJECTION_READ_SOURCE` stays `wal`.
The catalog read-cutover is a **separate** decision with its own runbook.
