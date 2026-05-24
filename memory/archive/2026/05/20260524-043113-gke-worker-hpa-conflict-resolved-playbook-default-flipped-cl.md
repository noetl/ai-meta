# GKE worker HPA conflict resolved — playbook default flipped, cluster patched
- Timestamp: 2026-05-24T04:31:13Z
- Author: Kadyapam
- Tags: gke,helm,keda,hpa,ops,handoff,closed

## Summary
Round 2 of 2026-05-24-gke-worker-hpa-conflict closed. Cluster-side: helm upgrade --reuse-values --set worker.autoscaling.enabled=false (rev 153→154); only keda-hpa-noetl-worker-scaler-worker-cpu-01 remains; worker stable at replicas=1 ready=1. Durable fix: ops PR #115 flips noetl_worker_autoscaling_enabled default to false in automation/gcp_gke/noetl_gke_fresh_stack.yaml (chart template was already correct — round-1 chart-template suggestion was a false lead). PR open, not merged.

## Actions
-

## Repos
-

## Related
-
