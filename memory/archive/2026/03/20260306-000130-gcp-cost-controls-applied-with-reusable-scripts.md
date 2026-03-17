# gcp cost controls applied with reusable scripts
- Timestamp: 2026-03-06T00:01:30Z
- Author: Kadyapam
- Tags: gcp,cost,logging,monitoring,networking,playbook,ops

## Summary
Applied project-level _Default logging exclusions for health/polling and repetitive stack traces, patched Managed Prometheus OperatorConfig to exclude container_network_* high-volume metrics, deleted unused reserved IP gateway-static-ip-cloudflare, and added reusable apply/rollback scripts plus playbook for cross-project execution.

## Actions
- [done] Applied `_Default` sink exclusions in `noetl-demo-19700101`:
  - `noetl_health_polling_lowvalue`
  - `clickhouse_stderr_stackframes`
  - `noetl_worker_nats_unavailable_spam`
  - `kube_system_chatty_lowseverity`
- [done] Patched `gmp-public/operatorconfig config` with `collection.filter.matchOneOf` to exclude high-volume `container_network_*` metrics.
- [done] Deleted unused reserved static external IP `gateway-static-ip-cloudflare`.
- [done] Added reusable apply/rollback scripts and runbook for cross-project execution.
- [todo] After 24h and 7d, compare billing metrics before/after:
  - `logging.googleapis.com/billing/bytes_ingested`
  - `monitoring.googleapis.com/billing/samples_ingested`
- [todo] Run this playbook on the next NoETL GKE project and record resulting deltas in a new memory entry.

## Repos
- `ai-meta`:
  - `scripts/gcp_cost_controls_apply.sh`
  - `scripts/gcp_cost_controls_rollback.sh`
  - `playbooks/gcp_cost_optimization_noetl.md`
- runtime cluster/project:
  - GKE cluster: `noetl-cluster` (`us-central1`)
  - GCP project: `noetl-demo-19700101`

## Related
- commits:
  - `d57b96c` (`docs(agents): add gcp cost optimization runbook and scripts`)
  - `3ee6722` (`memory(add): gcp cost controls applied with reusable scripts`)
- runbook:
  - `playbooks/gcp_cost_optimization_noetl.md`
