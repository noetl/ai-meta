# Rollback — T5-readiness deploy (2026-07-31, shastaratech prod)

Captured **before** any change. Every step is independent; take only the ones
matching what went wrong.

```bash
export CLOUDSDK_CORE_ACCOUNT=shastaratech@gmail.com   # NOT akuksin@gmail.com
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
K() { kubectl --context "$CTX" -n noetl "$@"; }
```

## Pre-change state

Bus was **already EHDB** on every workload (`NOETL_COMMAND_BUS=ehdb` on server,
user pool, both system pools). This deploy did **not** change the bus; it changed
images and turned autoscaling on. So "rollback" never means flipping the bus back
unless the bus itself regresses — see the last section.

| Workload | Image digest before |
|---|---|
| `noetl-server-rust` | `server-rust@sha256:b49e67fa0f5577816ae71aa5e7877028aa062f2e5f833b24a4908cd54c4c86a0` (**v3.58.3**) |
| `noetl-worker-rust` | `noetl-worker-rust@sha256:b28257e6cdcb4575b9ab562639b2a7f203b5eea9a32951ae464c1fae63b9b384` (**v5.81.3**) |
| `noetl-worker-system-pool` | same worker digest |
| `noetl-worker-system-pool-shard1` | same worker digest |
| `noetl-cmdbus-writer-0` | same worker digest |
| `noetl-cmdbus-writer-1` | same worker digest (scaled to 0) |

**The pre-change versions already carry #205 and #208** — v5.81.3 / v3.58.3 were
deployed 2026-07-30 11:07, after those merged. (The `194-l1-t4-prod-iac/env.sh`
comments still name v5.81.1 / v3.58.1 and are stale; the digests above were read
off the live cluster.) So this deploy's delta is only:

- **server v3.58.4** — the #291 publish-retry window (0.5 s → 10 s) + the ehdb re-pin.
- **worker v5.82.0** — the per-subject lag series + the resume gauges.

Rolling back therefore lands on a version that still survives a writer restart;
it does not reopen #208.

ScaledObject `noetl-worker-rust`: **paused**, `valueLocation:
ehdb_feed_total_lag`, both triggers present, min 2 / max 20. Full YAML in
`rollback/scaledobject-baseline.yaml`; all Deployments in
`rollback/deployments-baseline.yaml`.

## 1. Autoscaler misbehaving (scaling wrong, flapping, or on a bad signal)

Fastest first:

```bash
# (a) Re-pause.  Instant.  NOTE: this returns the pool to NO autoscaling at all —
#     KEDA 2.15 deletes the HPA when paused — and pins it at its CURRENT replica
#     count, which may be mid-scale-up.  Follow with an explicit scale.
K annotate scaledobject noetl-worker-rust autoscaling.keda.sh/paused=true --overwrite
K scale deploy noetl-worker-rust --replicas=2

# (b) Or revert just the trigger to whole-shard lag, staying unpaused.
K patch scaledobject noetl-worker-rust --type=json \
  -p='[{"op":"replace","path":"/spec/triggers/0/metadata/valueLocation","value":"ehdb_feed_total_lag"}]'

# (c) Or restore the exact pre-change object.
K apply -f rollback/scaledobject-baseline.yaml

# (d) Nuclear: no autoscaler at all.
K delete scaledobject noetl-worker-rust
K scale deploy noetl-worker-rust --replicas=2
```

## 2. New images bad (crashloop, dispatch regression, loss/dup)

Roll each Deployment back by digest. The writer is the one that matters for the
bus; do it first and, per #208's now-fixed behaviour, workers should redial on
their own — if they do not, that is itself the regression and restarting them is
the workaround.

```bash
W=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:b28257e6cdcb4575b9ab562639b2a7f203b5eea9a32951ae464c1fae63b9b384
S=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:b49e67fa0f5577816ae71aa5e7877028aa062f2e5f833b24a4908cd54c4c86a0

K set image deploy/noetl-cmdbus-writer-0 noetl-worker="$W"
K set image deploy/noetl-worker-rust noetl-worker="$W"
K set image deploy/noetl-worker-system-pool noetl-worker="$W"
K set image deploy/noetl-worker-system-pool-shard1 noetl-worker="$W"
K set image deploy/noetl-server-rust noetl-server="$S"
```

⚠ Container names on **prod** are `noetl-worker` and `noetl-server` — verified
2026-07-31. They are **not** the bare `worker` used in the kind topology; a wrong
container name makes `kubectl set image` a silent no-op that reports success.
Confirm before running:

```bash
K get deploy <name> -o jsonpath='{.spec.template.spec.containers[*].name}'
```

The rollback target v5.81.3 already contains the #208 fixes, so a writer restart
on it still recovers on its own — no worker restart needed. (That would **not**
be true of v5.81.1, which is what the older `194-l1-t4-prod-iac/env.sh` pins;
do not roll back that far without also restarting the worker pools.)

## 3. The bus itself regresses (loss, dup, dispatch stalled)

NATS is still installed and `NOETL_COMMANDS_RUST` still exists, so the T4-era
fallback is intact. This is a **bigger** step than an image rollback and changes
the transport — prefer 2 first.

```bash
for d in noetl-server-rust noetl-worker-rust noetl-worker-system-pool \
         noetl-worker-system-pool-shard1; do
  K set env deploy/$d NOETL_COMMAND_BUS=nats
done
```

The `nats-jetstream` trigger is still on the ScaledObject, so autoscaling
survives this flip.

## 4. Verifying a rollback took

```bash
K get deploy -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
K get scaledobject noetl-worker-rust
K get hpa
curl -s http://127.0.0.1:18099/api/health   # via port-forward svc/noetl-server-rust
```

Then fire one synthetic and confirm `COMPLETED`:

```bash
./drive-load.sh 1 1
```
