# ehdb#324 phases 6–10 — tier serve cutover runbook

**Status: PREPARED, NOT EXECUTED. Verdict below is NO-GO.**
Event log stays `primary` in name and the serve path is unchanged. Executing
the flip requires an explicit owner instruction.

## Current state (verified live, 2026-09-01)

```
server v3.99.5   worker/writer v5.129.1
NOETL_EHDB_EVENTLOG            = primary     NOETL_EHDB_PROJECTION             = shadow
NOETL_EHDB_KV                  = shadow      NOETL_EHDB_PROJECTION_READ_SOURCE = wal
NOETL_EHDB_OBJECT              = shadow      NOETL_EHDB_RECOVERY_SOURCE        = verify
NOETL_EHDB_TIER_QUERY_SOURCE   = service
```

## Pre-flip checks — run, with evidence

| # | check | result |
| :-- | :-- | :-- |
| C1 | equivalence baseline vs the oracle | **29/29 digest-equal, 0 divergent paths** ✅ |
| C2 | writer healthy, manifest bounded | v5.129.1, Ready, snaps **32** ✅ |
| C3 | `ehdb_l0_ingest_append_failed` | **0** ✅ |
| C4 | `ehdb_l0_out_of_order_appends` | **0** ✅ |
| C5 | single-writer **enforced** | replicas=1, 0 autoscalers, **`ehdb_election_active` absent** ❌ |
| C6 | `ehdb_l0_unreplicated_records` | **0** ✅ |
| C7 | independent failure domain | tier dir **nested inside** writer dir, one PVC (ehdb#332) ❌ |
| C8 | projection tier judgeable | **no sampler** (ai-meta#316) ❌ |
| C9 | disk headroom | cmdbus 1%, eventbus ~1.5% ✅ |
| C10 | dispatch healthy | 200 + execution_id ✅ |
| C11 | drift audit | **No drift found** ✅ |

## Verdict: **NO-GO** — three blockers, none of them latent

**C7 is the hard one.** `NOETL_EHDB_TIER_SERVICE_DIR=/data/eventbus/ehdb-tier`
is inside `NOETL_EVENT_BUS_WRITER_DIR=/data/eventbus`. Serving from a tier that
shares a physical volume with the log it is meant to be independent of means a
single volume loss takes both. Promoting to serve would convert a
one-disk-durability problem into a one-disk-**availability** problem.

**C5.** Single-writer ordering is the assumption every tier rests on, and it is
currently a *deployment property* (`replicas: 1`), not an enforced one.
Acceptable for a shadow tier. For a serving one it means a mis-scale — or an
Autopilot reschedule that briefly double-schedules — is a correctness event
with no fencing to stop it. `ShardElection` exists, is tested, and has no call
sites.

**C8.** The projection tier's divergence signal only moves when a human queries
it, so its clean readings are not evidence. Flipping a tier whose correctness
signal is unobserved is flipping blind.

C1–C4, C6, C9–C11 all pass, so the *data* story is in good shape. The blockers
are structural, not quality.

## The flip, when it is authorised

Per-tier, one env var, applied to the worker workloads that host the data plane:

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
# projection tier shadow -> primary (example; same shape for KV / object)
kubectl --context $CTX -n noetl set env \
  deploy/noetl-worker-rust deploy/noetl-worker-system-pool deploy/noetl-worker-system-pool-shard1 \
  NOETL_EHDB_PROJECTION=primary
# and, to actually SERVE reads from it:
kubectl --context $CTX -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_PROJECTION_READ_SOURCE=tier
```

**Rollback — one command, no image change, takes effect on pod restart:**

```bash
kubectl --context $CTX -n noetl set env \
  deploy/noetl-worker-rust deploy/noetl-worker-system-pool deploy/noetl-worker-system-pool-shard1 \
  NOETL_EHDB_PROJECTION=shadow
kubectl --context $CTX -n noetl set env deploy/noetl-server-rust \
  NOETL_EHDB_PROJECTION_READ_SOURCE=wal
```

## Blast radius

- **Flipping the mode flag alone** (`shadow` → `primary`) changes what is
  *written*, not what is *read*. Low risk, reversible.
- **Flipping `READ_SOURCE`** is the real cutover: reads start being served from
  the tier. If the tier is wrong or unavailable, callers get wrong or failed
  answers. This is the step that needs C5/C7/C8 closed.
- ⚠ These are **two separate decisions.** Treat `primary` and `READ_SOURCE` as
  independent gates; conflating them is how a "safe mode change" becomes a
  serve cutover.
- Rollback is an env change, so it costs a pod restart — for the writer that is
  a ~90 s dispatch interruption.

## Post-flip verification (the same oracle, re-run)

Re-run the Step-2 burst and sweep. **Expect 29/29 (or 30/30) digest-equal
again.** Any drop is now meaningful: since v3.99.5 the digest is canonical for
sets, so a disagreement is a real divergence rather than a permutation
artifact. That is precisely why the baseline had to be re-established first.
