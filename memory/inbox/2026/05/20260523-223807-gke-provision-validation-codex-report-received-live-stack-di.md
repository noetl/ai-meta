# GKE provision validation — codex report received; live stack diverges from ops-manifest assumption
- Timestamp: 2026-05-23T22:38:07Z
- Author: Kadyapam
- Tags: noetl,gke,handoff,codex,validation,keda,nats-supercluster,helm-divergence

## Summary
Codex executed the GKE validation handoff against gke_noetl-demo-19700101_us-central1_noetl-cluster. Result file at handoffs/active/2026-05-23-gke-provision-validation/round-01-result.md (status: partial, commit 18077c9). What worked: KEDA install + ScaledObject (after 3 live patches), NATS supercluster (3+3 pods, bidirectional gateway mesh dynamically PVC-bound on standard-rwo), 5 test/simple_python executions (1 cold-with-backlog at 168s, 4 warm at 1.0–4.0s), API health HTTP 200 in 140ms via port-forward, 1163-playbook catalog. What revealed gaps (NOT Scope-B regressions — real GKE-vs-kind divergence): (1) live GKE stack is Helm-managed Cloud SQL + PgBouncer, NOT the ops-manifest deployment/postgres — the dev playbook was never the deploy path here. (2) KEDA sample manifest needed three patches: natsServerMonitoringEndpoint → nats-headless..., account NOETL → $G, plus deletion of a competing Helm HPA. (3) Worker durable consumer NOETL_COMMANDS/noetl_worker_pool was missing — codex created it manually (pull, deliver=new, ack_wait=15m30s, max_ack_pending=64, max_deliver=1000). (4) test/simple_python wasn't registered; loaded from repos/e2e fixtures. (5) Stale Pending PVCs from old static-PV attempts linger in noetl + postgres namespaces. Codex opened a follow-up handoff at handoffs/active/2026-05-23-gke-playbook-hardening/ requesting four pieces of work: GKE-safe playbook path (registry images, no Podman, dynamic PVCs), KEDA overlay for Helm NATS service/account shape, deterministic worker consumer bootstrap, and a decision on whether GKE should use Helm Cloud SQL or ops-manifest Postgres. Manual escalation: ai-meta needs to decide the GKE database topology before the hardening round can land. Side-by-side metrics in result file.

## Actions
-

## Repos
-

## Related
-
