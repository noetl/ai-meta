# noetl-worker consumer-drift root-caused — recovery in PR #600
- Timestamp: 2026-05-24T00:04:10Z
- Author: Kadyapam
- Tags: noetl,gke,worker,nats,consumer-drift,bugfix,codex,handoff

## Summary
Codex's diagnostic round on the GKE worker-consumer-missing finding ruled out all four of my original hypotheses (Helm command override, crash-loop, env divergence, wrong NATS endpoint) and identified a fifth: durable-consumer drift after worker startup. When NOETL_COMMANDS/noetl_worker_pool disappears while workers are already subscribed (e.g. NATS pod restart, admin op, stream recreation), the fetch loop catches ServiceUnavailableError forever and the pod stays 1/1 Running from Kubernetes' view — never reconciling. Codex's earlier validation log showed suppressed=1422844 duration=146152.0s (≈40 hours of suppressed errors) which is exactly this state. Phase D reproduced: delete consumer with nats CLI → existing worker stays Running but logs ServiceUnavailableError; kubectl rollout restart → new worker recreates consumer immediately. Fix: noetl/noetl#600 adds _recover_fetch_subscription() to NATSCommandSubscriber — called on fetch exceptions, rate-limited 30s, re-runs _ensure_consumer + rebuilds pull_subscribe. Startup behavior unchanged. 14 tests pass in tests/core/test_nats_command_subscriber.py. PR awaiting review + merge. Side findings: (1) worker logs leak NATS_URL with embedded credentials — needs redaction follow-up; (2) GKE image is the May-20 e3db3624 tag, predates the fix — cluster won't self-heal until a new image with #600 ships; (3) env tuning differences between Helm worker and ops-manifest worker (NOETL_DISABLE_METRICS=true, lower inflight, GCS tier) don't explain the missing consumer but contribute to the broader GKE-vs-kind divergence audit. Result file: handoffs/active/2026-05-23-gke-worker-consumer-missing/round-01-result.md (status: complete).

## Actions
-

## Repos
-

## Related
-
