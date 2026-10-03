# Runbook — server Deployment → StatefulSet cutover (#419, ops#303)

**DESIGN ONLY. Not executed. Requires explicit owner go.**
Written 2026-09-09. Target: `noetl-server-rust` in `shastaratech-noetl-prod`.

## What this is for

The embedded engine needs a persistent volume before it can serve reads. A
volume needs a StatefulSet (see ops#303 for why neither RWO nor RWX on the
existing Deployment works). This runbook moves the running server onto that
StatefulSet.

It does **not** flip serving to the embedded engine — that is a separate gate
([FLIP-serve-from-embedded.md](FLIP-serve-from-embedded.md)).

## ⚠⚠ Two hazards that decide the whole shape

### 1. Two servers must never serve at once

`chain_heads` is **in-memory per replica**, and the server's own docs say it:
*"concurrent cross-replica emits for one execution fork the chain."* Execution
affinity exists to prevent exactly this, and it is **off** in prod
(`shard_count = 1`, no peer template).

So the naive "bring the StatefulSet up, then repoint the Service" is wrong: it
puts two independent servers on the same database with no affinity between them.

Worse, a *standby* server is not passive. It runs the reconcile poller, the
orphan sweep, the nonconvergence sweep (**armed in prod**), and the parity
sampler — all against the shared database. Two orphan sweeps and two
nonconvergence sweeps running concurrently is its own incident.

⇒ **The cutover requires a deliberate serving gap.** The old pod must be gone
before the new one starts. Roughly 30–60 s at `/api/execute`, which workers
retry through. Design for the gap; do not try to engineer it away.

### 2. `kubectl apply` cannot remove a Service selector key

Already cost an outage once on this platform: an apply that *omitted* a selector
key left it in place, leaving **zero endpoints behind a healthy pod**. The
selector change here replaces `app: noetl-server-rust` with
`app: noetl-server-rust-embedded`, i.e. a key whose value changes — safe — but if
the label set is ever restructured, use an explicit patch and verify endpoints
rather than assuming apply removed anything.

Verify endpoints after every selector change:
```bash
kubectl -n noetl get endpoints noetl-server-rust -o wide      # must be non-empty
```

## Pre-flight (no changes)

1. **PVC storage class exists and binds**: `standard-rwo` is the cluster default
   and `WaitForFirstConsumer`, so the PVC stays `Pending` until the pod
   schedules. That is normal — do not treat `Pending` as failure before the pod
   exists.
2. **Full-spec diff of the StatefulSet against live** (there is no live object
   yet, so this is a create):
   ```bash
   kubectl -n noetl apply --server-side --dry-run=server -f ci/manifests/noetl/embedded-state/server-statefulset-embedded.yaml
   ```
   Expect exactly two objects, and confirm the output names **no existing
   workload**.
3. **Record the rollback digest** from `RELEASE-LEDGER.md` and the live object:
   ```bash
   kubectl -n noetl get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```
4. **Confirm prod is quiet** — no active executions worth interrupting, no
   reconcile backlog, `no-op/min ≈ 0`.

## Cutover

Each step lands in a known-good state before the next.

| # | step | verify before continuing |
| :-- | :-- | :-- |
| 1 | Create the StatefulSet **at `replicas: 0`** and its headless Service | both objects exist; **no pod**; existing Deployment untouched (`generation` unchanged) |
| 2 | Scale the Deployment to 0 | pod gone; **serving gap starts** |
| 3 | Scale the StatefulSet to 1 | pod `Running` **1/1**; PVC `Bound`; log shows the engine opened on `/data/ehdb-embedded` |
| 4 | Repoint `Service/noetl-server-rust` selector → `app: noetl-server-rust-embedded` | `endpoints` non-empty and pointing at the new pod IP; **serving gap ends** |
| 5 | Canary: one real execution end-to-end | accepted in normal time **and** reaches a terminal event |
| 6 | Soak 15 min | 0 ERROR, 0 restarts, no-op/min ≈ 0, dispatch normal |

⚠ Step 1 creating at `replicas: 0` is deliberate: it separates "the object is
accepted by the API" from "a second server is running", so a manifest problem
surfaces while the old server is still serving.

## Rollback (any step)

Reverse, in this order:

1. Repoint the Service selector back to `app: noetl-server-rust`.
2. Scale the Deployment back to 1.
3. Scale the StatefulSet to 0.

The Deployment object is **never deleted** during cutover — that is what makes
rollback a scale operation rather than a re-create. Delete it only after the
StatefulSet has soaked, as a separate change.

⚠ Rollback is *not* symmetric in one respect: events written while the
StatefulSet served are in Postgres and are authoritative regardless. Only the
embedded engine's local state is lost, and in this runbook it is still a shadow,
so nothing depends on it.

## What this runbook deliberately does not do

- **No serve flip.** The engine stays in shadow across the whole cutover; the
  volume is a prerequisite, not the change.
- **No N>1.** `replicas: 1` throughout. Sharding is a later step and needs the
  affinity config validated in kind (which it now is).
- **No Deployment deletion.** Left in place as the rollback path.
