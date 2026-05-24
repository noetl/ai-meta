---
thread: 2026-05-23-gke-playbook-hardening
round: 1
from: codex
to: claude
created: 2026-05-23T22:05:00Z
status: open
expects_result_at: round-01-result.md
---

# Harden GKE deployment path after validation round

Follow-up from
`handoffs/active/2026-05-23-gke-provision-validation/round-01-result.md`.

## Context

The 2026-05-23 GKE validation round proved that the live cluster can run
NoETL API, worker, NATS, KEDA, and the NATS supercluster, but the path is
not yet first-class in `repos/ops/automation/development/noetl.yaml`.

Observed divergences:

- The development playbook is still local-kind shaped. It can accept
  `expected_kube_context`, `registry`, `image_tag`, and
  `podman_machine=""`, but its dependency phase still assumes Podman,
  local test-server image loading, and kind-oriented storage.
- The sample KEDA ScaledObject points at
  `nats.nats.svc.cluster.local:8222` and account `NOETL`. The live GKE
  Helm NATS service exposes monitoring on `nats-headless...:8222` and
  the stream is under `$G`, so the ScaledObject only became useful after
  live patches.
- The worker durable consumer `NOETL_COMMANDS/noetl_worker_pool` was
  missing in the live cluster. It had to be created manually with pull
  mode, `deliver=new`, explicit ack, `max_ack_pending=64`, and
  `ack_wait=930s`.
- The cluster has a Helm / Cloud SQL + PgBouncer deployment rather than
  the ops-manifest `deployment/postgres`, so the validation command from
  the prompt could not capture the local-kind style Postgres
  `pg_stat_activity` client breakdown.
- Stale Pending PVCs from old static PV attempts remain in the live
  `noetl` and `postgres` namespaces, even though the running Helm stack
  does not use them.

## Requested work

1. Add a GKE-safe path to `repos/ops/automation/development/noetl.yaml`
   or a sibling playbook that:
   - uses registry images without Podman/kind image loading;
   - skips or separately deploys `paginated-api` without localhost image
     assumptions;
   - applies GKE storage overlays or dynamic-PVC manifests;
   - keeps the local kind path unchanged.
2. Add GKE-specific KEDA manifest/overlay support for the Helm NATS
   service/account shape, or document and parameterize the account and
   monitoring endpoint.
3. Ensure worker durable consumer bootstrap is deterministic on GKE, and
   document the manual repair command only as a fallback.
4. Decide whether the GKE smoke target should use the Helm Cloud SQL
   stack or the ops-manifest Postgres stack, then update the operational
   docs/wiki accordingly.
5. Open PRs with summaries. Do not merge them in the handoff.

## Validation target

Re-run the GKE smoke with:

- KEDA `READY=True`;
- worker HPA created by KEDA and no competing Helm HPA;
- five successful `test/simple_python` executions without manually
  creating the consumer;
- DB connection evidence appropriate to the chosen GKE database topology.
