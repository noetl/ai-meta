# Inline-execution rolled out via chart on noetl-demo GKE — helm rev 171, durable across upgrades
- Timestamp: 2026-05-26T16:45:01Z
- Author: Kadyapam
- Tags: noetl,ops,inline-execution,gke,helm,enforce,close-out

## Summary
noetl/ops PR #119 merged as 06f11f6; ai-meta pointer bumped. Helm upgrade applied on the noetl-demo-19700101 GKE cluster (helm rev 171) with --reuse-values --set config.worker.NOETL_INLINE_TRIVIAL_CHILDREN=enforce. Then kubectl set env deployment/noetl-worker NOETL_INLINE_TRIVIAL_CHILDREN- NOETL_WORKER_HTTP_TIMEOUT- to strip the older direct env overrides so the ConfigMap-backed value wins. End state: ConfigMap noetl-worker-config has NOETL_INLINE_TRIVIAL_CHILDREN=enforce; deployment direct env empty for this key; pod runtime env=enforce sourced via envFrom configMapRef. Durable across future helm upgrades because it's now in the chart. Post-rollout smoke (exec 635409257185149227): duration 1.054s, inline_decision.inline=True, meta.inline_mode=worker, child exec_id 18 chars, all canned-diagnosis markers present. Round B inline-execution arc fully closed end-to-end: code (noetl PRs #608-#611 + #613-#616), chart (ops PR #119), live GKE rollout, wiki, handoff archived, sync note complete.

## Actions
-

## Repos
-

## Related
-
