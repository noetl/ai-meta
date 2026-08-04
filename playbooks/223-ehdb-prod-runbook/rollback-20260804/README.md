# P4a rollback artefacts — 2026-08-04

Saved before the ops#245 Deployment→StatefulSet converge.

## What is here

| File | Use |
| :-- | :-- |
| `writer-deployment.yaml` | **the rollback artefact** — the pre-converge writer Deployment |
| `writer-service-shard0.yaml` | the per-shard Service with its original `app:` selector |
| `writer-deployments-all.yaml` | both writer Deployments (shard 0 + the dormant shard 1) |
| `pvcs.yaml` | all four PVCs (never deleted by the playbook; here for reference) |
| `all-services.yaml`, `scaledobjects.yaml`, `podmonitoring.yaml` | surrounding state |

## Deliberately NOT committed

`all-deployments.yaml` and `gateway-deployment.yaml` were captured but are
**excluded from this repo**: their `kubectl.kubernetes.io/last-applied-configuration`
annotations embed a plaintext `NATS_URL=nats://noetl:noetl@…` credential
(noetl/ai-meta#188) and the gateway's Auth0 client id. This repo is public and
`agents/rules/safety.md` forbids storing credentials, so they are kept only in
the operator's local scratch.

Neither is needed for the writer rollback below. Re-capture them live if
required:

```bash
kubectl -n noetl   get deploy  -o yaml > all-deployments.yaml
kubectl -n gateway get deploy gateway -o yaml > gateway-deployment.yaml
```

## Rollback

```bash
K() { kubectl --context gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot -n noetl "$@"; }
K scale sts/noetl-cmdbus-writer --replicas=0
K wait --for=delete pod/noetl-cmdbus-writer-0 --timeout=180s
K apply -f writer-deployment.yaml
K apply -f writer-service-shard0.yaml     # restores the app: selector
K rollout status deploy/noetl-cmdbus-writer-0 --timeout=600s
```

The PVCs are never deleted by the playbook, so the durable log is intact across
a rollback.
