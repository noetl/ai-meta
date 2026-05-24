# v2.100.5 deployed to GKE — all three fixes verified live; HPA conflict surfaced
- Timestamp: 2026-05-24T03:20:37Z
- Author: Kadyapam
- Tags: noetl,gke,deploy,v2.100.5,fixes-verified,handoff,hpa-conflict

## Summary
Codex completed the deploy-and-verify handoff. Cloud Build 302d76b0 produced us-central1-docker.pkg.dev/noetl-demo-19700101/noetl/noetl:v2.100.5 in 2m33s. helm upgrade --reuse-values rolled the Helm release 'noetl' from revision 152 → 153 with rolling-update on noetl-server and noetl-worker; pre-deploy image was pftlog-e3db3624-20260521115509 (May-20 e3db3624, kept as rollback). Three fixes verified on the live cluster: (1) #601 redaction — worker startup logs show nats://[REDACTED]@... verbatim; the prompt's /tmp/worker_config.txt is absent in this image variant but the runtime logs are clean. (2) #600 consumer drift self-heal — codex deleted NOETL_COMMANDS/noetl_worker_pool, waited, observed the running worker pod recreating it WITHOUT pod restart (restart count stayed at 0 — proves in-flight recovery on live cluster, evidence we couldn't get from local kind). (3) #602 catalog scope fix — verified by grepping the deployed source inside the running container. Smoke: API health HTTP 200 in 261ms, 1164 catalog entries, 5 test/simple_python executions completed in 0.56s-2.07s range (comparable to or better than the previous GKE round's 0.97s-3.99s). KEDA: Ready=True, retained the live patches (account=$G, natsServerMonitoringEndpoint=nats-headless.nats.svc.cluster.local:8222). Pre-existing v2.88.1 cluster posture cleaned up to v2.100.5. Commit 40077fb. Open follow-up: handoffs/active/2026-05-24-gke-worker-hpa-conflict/ — codex surfaced a Helm chart vs. KEDA HPA conflict. The chart renders its own CPU-based 'noetl-worker' HPA (max 8) while the external KEDA-managed 'keda-hpa-noetl-worker-scaler-worker-cpu-01' (max 20) targets the same Deployment. During deploy: two HPAs oscillated the desired replicas, pods went Pending briefly. Values shape: worker.autoscaling.enabled=true + worker.autoscaling.keda.enabled=false — chart logic doesn't suppress CPU HPA when external KEDA is in play. Quick fix: helm upgrade --reuse-values --set worker.autoscaling.enabled=false. Durable fix: update the chart template to skip the CPU HPA when KEDA is expected to own the worker scaling.

## Actions
-

## Repos
-

## Related
-
