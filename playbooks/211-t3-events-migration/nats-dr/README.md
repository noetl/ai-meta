# NATS disaster-recovery snapshot

Captured 2026-07-31 from
`gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot`, immediately
before the EHDB-only cutover and NATS teardown.

**This is a recovery path, not a fallback.** NATS is deleted from this cluster.
Nothing runs against these definitions. They exist so NATS *could* be recreated
if the EHDB bus turns out to be irrecoverably wedged.

## What is here

| File | What it is |
| :-- | :-- |
| `stream-noetl_events.json` | The events stream: `noetl.events.>`, file storage, 1 replica, `max_age` 24h, dedup window 120s |
| `stream-NOETL_COMMANDS_RUST.json` | The (already idle) command stream |
| `consumer-noetl_materializer.json` | Durable pull consumer — was the **sole writer** of `noetl.event` |
| `consumer-noetl_result_materializer.json` | Result-tier materializer |
| `consumer-noetl_state_materializer.json` | State projection materializer |
| `consumer-noetl_projector.json` | Orphaned consumer (never delivered; 18k unprocessed) |
| `kv-sessions.json` | `KV_sessions` backing stream — `$KV.sessions.>`, TTL 300s, 1 msg/subject |
| `kv-requests.json` | `KV_requests` backing stream — `$KV.requests.>`, TTL 300s, 1 msg/subject |
| `k8s-nats-statefulset.yaml` | The `nats` StatefulSet as deployed |
| `k8s-nats-services.yaml` / `k8s-nats-configmaps.yaml` / `k8s-nats-pvc.yaml` | Its Services, config, and 5Gi PVC |
| `k8s-nats-supercluster.yaml` | The whole `nats-supercluster` namespace (6 pods, `nats-cluster-a` + `-b`) — no workload ever referenced it |

## What is NOT here, deliberately

**No message data.** These are *definitions* only. The events stream held ~18k
messages under a 24h TTL, all of which were already materialized into
`noetl.event` — the durable log is the system of record and is untouched by any
of this. The KV buckets were empty (`0 values, Last Update: never`), so there is
nothing to snapshot.

If a restore is ever needed, the streams come back **empty**, which is correct:
their content was transient by construction.

## Restore recipe

```bash
export CLOUDSDK_CORE_ACCOUNT=shastaratech@gmail.com
export KCTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot

# 1. Namespace + server
kubectl --context $KCTX create namespace nats
kubectl --context $KCTX -n nats apply -f k8s-nats-configmaps.yaml
kubectl --context $KCTX -n nats apply -f k8s-nats-pvc.yaml
kubectl --context $KCTX -n nats apply -f k8s-nats-services.yaml
kubectl --context $KCTX -n nats apply -f k8s-nats-statefulset.yaml
kubectl --context $KCTX -n nats rollout status statefulset/nats

# 2. Streams + KV (from a nats-box pod; strip runtime state first — `nats
#    stream add --config` wants the `config` object, not the full info doc)
python3 -c "import json;print(json.dumps(json.load(open('stream-noetl_events.json'))['config']))" \
  > /tmp/noetl_events.cfg.json
# then: nats stream add noetl_events --config /tmp/noetl_events.cfg.json

# 3. The server + workers recreate their own consumers at startup
#    (EventStreamPublisher::ensure_consumer), so the consumer-*.json files are
#    reference only — do not hand-create them.

# 4. Re-add the NATS env removed at teardown (see ../ROLLBACK.md for the
#    baseline table) and set NOETL_EVENT_BUS=nats.
```

**The `nats-supercluster` namespace is intentionally excluded from the restore
recipe.** Nothing referenced it; recreating it would restore an unexplained cost,
not a capability. Its manifest is kept only so the decision can be revisited with
evidence.

## The credential

Every URL in these manifests embeds the plaintext `noetl:noetl` credential
([#188](https://github.com/noetl/ai-meta/issues/188)). A restore must rotate it
rather than reuse it — the teardown is what retires that credential, and bringing
it back verbatim would undo that.
