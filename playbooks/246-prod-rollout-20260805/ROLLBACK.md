# ROLLBACK — prod rollout 2026-08-05

Captured BEFORE any change. Every command below is copy-paste runnable.

## Digests (the authority — tags can move, digests cannot)

| workload | replicas | container | rollback image |
| :-- | :-- | :-- | :-- |
| `noetl-server-rust` | 1 | `noetl-server` | `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:fefa0e4c4b5308f34795a477044444c6c307b3b7a12a0fb7c307c2c9e7942ae1` |
| `noetl-worker-rust` | 2 | `noetl-worker` | `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:02947702efedc3780b93a3e5f831d815ecf45226484135c0e8adda6509850e38` |
| `noetl-worker-system-pool` | 1 | `noetl-worker` | same worker digest |
| `noetl-worker-system-pool-shard1` | 1 | `noetl-worker` | same worker digest |
| `noetl-cmdbus-writer` (StatefulSet) | 1 | — | untouched in Phase 1 unless stated |

Server digest = v3.62.1. Worker digest = v5.95.3.

## Roll back (one workload)

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
SRV=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:fefa0e4c4b5308f34795a477044444c6c307b3b7a12a0fb7c307c2c9e7942ae1
WRK=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:02947702efedc3780b93a3e5f831d815ecf45226484135c0e8adda6509850e38

kubectl --context $CTX -n noetl set image deploy/noetl-server-rust               noetl-server=$SRV
kubectl --context $CTX -n noetl set image deploy/noetl-worker-rust               noetl-worker=$WRK
kubectl --context $CTX -n noetl set image deploy/noetl-worker-system-pool        noetl-worker=$WRK
kubectl --context $CTX -n noetl set image deploy/noetl-worker-system-pool-shard1 noetl-worker=$WRK
```

## Roll back everything at once

```bash
for d in noetl-server-rust noetl-worker-rust noetl-worker-system-pool noetl-worker-system-pool-shard1; do
  kubectl --context $CTX -n noetl rollout undo deploy/$d
done
```

`rollout undo` is the faster lever; the explicit digests above are the
authority if the revision history is not what you expect.

## Health gates (all must hold after each step)

- `ehdb_events_group_lag` → returns to 0
- `ehdb_events_cursor_errors` → 0
- `ehdb_l0_out_of_order_appends` → 0
- a real execution reaches COMPLETED, with the events cursor advancing
- no pod restarts, no CrashLoopBackOff
