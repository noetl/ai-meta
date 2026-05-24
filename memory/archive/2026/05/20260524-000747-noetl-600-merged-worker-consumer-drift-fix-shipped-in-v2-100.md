# noetl#600 merged — worker consumer-drift fix shipped in v2.100.3
- Timestamp: 2026-05-24T00:07:47Z
- Author: Kadyapam
- Tags: noetl,gke,worker,consumer-drift,bugfix,handoff,milestone

## Summary
Codex's diagnostic round delivered: PR #600 merged at d69c313d (noetl v2.100.3). NATSCommandSubscriber now self-heals when the durable consumer drifts at runtime — fetch loop catches the exception, calls _recover_fetch_subscription (rate-limited 30s) which re-runs _ensure_consumer and rebuilds pull_subscribe. Closes the silent failure mode where workers stayed 1/1 Running while logging ServiceUnavailableError forever after NOETL_COMMANDS/noetl_worker_pool disappeared (NATS restart, admin op, stream recreation). Archived both diagnostic threads: 2026-05-23-gke-provision-validation (partial — remaining open items in playbook-hardening) and 2026-05-23-gke-worker-consumer-missing (complete — root cause + fix). Pointer: noetl 65a02bf4 → 25e62eb5. Still active: handoffs/active/2026-05-23-gke-playbook-hardening/ (codex-opened follow-up for first-class GKE deploy path). The GKE cluster's existing worker image (May-20 e3db3624) does NOT yet contain the fix — needs a new image build + Helm deploy to pick it up. Until then, the cluster still relies on the manual consumer codex created in the validation round.

## Actions
-

## Repos
-

## Related
-
