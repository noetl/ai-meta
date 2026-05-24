# KEDA ScaledObject promoted to chart-templated NATS-JetStream artifact (GKE Option A)
- Timestamp: 2026-05-24T04:54:05Z
- Author: Kadyapam
- Tags: gke,keda,helm,ops,handoff,closed,option-a

## Summary
Thread 2026-05-24-keda-chart-template closed in one round. ops PR #116 merged: chart template worker-keda-scaledobject.yaml rewritten from Prometheus to nats-jetstream trigger; values.yaml gained worker.autoscaling.keda.nats.* defaults ($G, nats-headless...:8222, NOETL_COMMANDS, noetl_worker_pool); maxReplicas bumped 8->20; gke fresh-stack playbook flipped autoscaling.enabled=true + keda.enabled=true (reverses the post-#115 false default; the chart's mutually-exclusive guards keep CPU HPA and KEDA from coexisting). Live GKE cluster migrated to chart-rendered scaledobject.keda.sh/noetl-worker + keda-hpa-noetl-worker; external noetl-worker-scaler-worker-cpu-01 deleted; Helm rev 154->156; smoke run 633599564905185763 5.317s OK. Two issues surfaced and documented: helm --reuse-values does not merge new chart defaults (needed explicit --set on migration); KEDA admission webhook requires deleting prior ScaledObject before creating a new one for the same target. Kind-profile external file at ci/manifests/keda/scaledobject-worker-cpu-01.yaml unchanged (drift-guard-pinned to noetl.core.runtime.keda generator).

## Actions
-

## Repos
-

## Related
-
