# P4 — the IaC converge: DONE. Prod's EHDB topology is now declared.

**Run 2026-08-04 07:24 UTC against `shastaratech-noetl-prod` from ops#245 at
`5e28543`, on worker v5.92.1. Converged and verified. No rollback needed.**

The Deployment→StatefulSet writer handover — the most invasive step in the
runbook — is done, and **the durable log came through it without losing a
record**.

## Result

| | Before | After |
| :-- | :-- | :-- |
| Writer workload | Deployment `noetl-cmdbus-writer-0` | **StatefulSet `noetl-cmdbus-writer`** (gen 1, 1/1), pod `noetl-cmdbus-writer-0` |
| PVCs | 3 in use | **the same 3**, adopted by name — same PV UIDs, 8d/3d old |
| `volumeClaimTemplates` | n/a | **empty** — no fresh volumes provisioned |
| Writer Service selector | `{"app":"noetl-cmdbus-writer-0"}` | `{"statefulset.kubernetes.io/pod-name":"noetl-cmdbus-writer-0"}` |
| Writer Service endpoints | 1 | **1** (`10.119.1.110`) — not `<none>` |
| Grace period | 90 | 60 (still ≫ the 15 s seal budget) |
| Probes | `tcpSocket :9090` | `tcpSocket :9101` (`cmdbus-claim`) |

## The plan, read before applying

`action=plan` server-side dry-ran everything. The three gates that would have
stopped the converge all passed:

- **`storage=claim`, zero `volumeClaimTemplates`** — the plan mounts the three
  live PVCs by exact name (`noetl-cmdbus-writer-0-data`,
  `noetl-eventbus-writer-0-data`, `noetl-eventbus-kv-0-data`). Nothing would
  provision fresh volumes.
- **No PVC deletion anywhere.**
- **The 8th-defect Service selector is handled explicitly**, and the plan says
  so in as many words:

```
service/noetl-cmdbus-writer-headless created (server dry run)
service/noetl-cmdbus-writer-0 configured (server dry run)
statefulset.apps/noetl-cmdbus-writer created (server dry run)
  PLAN selector on Service/noetl-cmdbus-writer-0 will be REPLACED
       live:   {"app":"noetl-cmdbus-writer-0"}
       wanted: {"statefulset.kubernetes.io/pod-name":"noetl-cmdbus-writer-0"}
       (apply alone would keep the extra key and the Service would select nothing)
```

The rendered runtime env matched prod exactly — all four `_SOURCE=ehdb`,
`NOETL_STATE_BUILDER=offserver`, `NOETL_STATE_SHARD_WRITE=true`,
per-pool `shared.>` / `system.>` subjects, gateway on `:9105` / `:9107`.

## The converge

> **Operational note.** The `noetl run` was killed by a 2-minute tool timeout
> **during the verify phase**, after every reconcile step had completed. The
> reconcile itself — writer, runtime, gateway — was fully applied; only the
> IaC's own 20-execution probe was cut short. Verified independently below, and
> the IaC's `action=status` (which fires no executions) was re-run to completion
> and passed every assertion. A longer timeout is needed for a `converge` that
> chains into `verify`.

### Cursor continuity — the thing that mattered

```
command bus   from_cursor=52047  origin="persisted"  tip=52050  stored=52047
              clamped=false  replay_records=3

noetl_materializer         stored=4083  tip=4083  from=4083  clamped=false  replay_records=0
noetl_result_materializer  stored=4083  tip=4083  from=4083  clamped=false  replay_records=0
noetl_state_materializer   stored=4083  tip=4083  from=4083  clamped=false  replay_records=0
```

**`clamped=false` on all four, and all three event groups resumed at exactly
their persisted cursor with zero replay.** The durable command and event logs
survived the handover intact. This is v5.92.1's seal doing its job through a
deliberate writer-pod drop — the precise thing #226 broke and the reason P4 was
gated on it.

### Verification

| Gate | Result | |
| :-- | :-- | :-- |
| Writer is a StatefulSet, pod `noetl-cmdbus-writer-0` | yes, gen 1, 1/1 | ✅ |
| Same PVC objects (no new provisioning) | same 3 claims, same PV UIDs | ✅ |
| `clamped=false`, cursor continuous | all four feeds | ✅ |
| **Writer Service resolves to endpoints** | `10.119.1.110` — **not `<none>`** | ✅ |
| All nine faces listening | 9100–9108 (+9090), read from inside the pod | ✅ |
| Old writer Deployment drained | `NotFound` | ✅ |
| `bus=ehdb`, no `NATS_*` env | asserted on all 4 workloads | ✅ |
| All four `_SOURCE=ehdb`, both system pools | asserted | ✅ |
| `NOETL_RESULT_MINT_AUTHORITATIVE=true` preserved | yes — strategic merge does not prune | ✅ |
| Gateway `NOETL_KV_ADDR` / `NOETL_EVENT_FEED_ADDR` | asserted | ✅ |
| KEDA ScaledObject + HPA intact | Ready, not paused, HPA present | ✅ |
| All group lags → 0, `cursor_errors` 0, `out_of_order` 0 | yes | ✅ |
| **One synthetic execution** | **COMPLETED**, `grp_committed +31`, durable events **31** | ✅ |
| SSE | gateway attached to `:9105` on the new pod, 0 errors in 10 min | ✅ |

The IaC's own `action=status` was re-run and printed `OK` for every face, every
EHDB-only assertion, the gateway addresses, the HPA, and the trigger metric.

## Two things worth carrying forward

1. **Prod's topology now matches an unmerged PR branch.** ops#245 is still
   `OPEN` at `5e28543`. Prod is running exactly what that branch declares, so
   the branch should be merged promptly — until it is, the source of truth for
   prod's topology is a PR, and there is no ai-meta pointer bump for
   `repos/ops` (deliberately: the convention is to bump after merge).
2. **Idempotence was not re-tested.** The runbook's gate ("a second converge
   bumps no `.metadata.generation`") was skipped, because re-running `converge`
   chains into the 20-execution verify burst, which #227 makes undesirable right
   now. Generations were recorded before the status run
   (`StatefulSet/noetl-cmdbus-writer gen=1`) so the check is cheap to do later.

## Rollback (not used, still valid)

Saved in `playbooks/223-ehdb-prod-runbook/rollback-20260804/` — writer
Deployment, its Services (including the imperative per-shard selector), all
PVCs, ScaledObjects, all Deployments, the PodMonitoring and the gateway
Deployment. Verified non-truncated (env, ports, volumeMounts, probes, 3 PVCs
present).

```bash
K scale sts/noetl-cmdbus-writer --replicas=0
K wait --for=delete pod/noetl-cmdbus-writer-0 --timeout=180s
K apply -f rollback-20260804/writer-deployment.yaml
K apply -f rollback-20260804/writer-service-shard0.yaml   # restores the app: selector
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=600s
```

The PVCs are never deleted by the playbook, so the durable log is intact across
a rollback.

## Status

**P4 converged; prod is on the IaC.** Held before the post-P4 full
re-validation burst and the #227 cleanup, as instructed.
