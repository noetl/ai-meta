# Gateway login outage after wrong-context local playbook apply
- Timestamp: 2026-03-11T00:55:31Z
- Author: Kadyapam
- Tags: incident,gke,gateway,auth,cors,ops,safety

## Summary
Investigated login failures reported as CORS errors on mestumre.dev; root cause was noetl API outage in GKE caused by POSTGRES_HOST drift to postgres.postgres.svc.cluster.local after local kind playbook was run with GKE kubectl context. Applied runtime hotfix to noetl configmaps to use pgbouncer.postgres.svc.cluster.local, restarted noetl server/worker, confirmed endpoint recovery, and validated gateway login path returns expected 401 with Access-Control-Allow-Origin (no 502). Added guard in repos/ops automation/development/noetl.yaml to refuse deploy/status actions unless kubectl context is kind-noetl.

## Actions
- Diagnosed user-facing symptom:
  - Browser showed CORS failure on `POST https://gateway.mestumre.dev/api/auth/login`.
  - Verified preflight CORS was correct; actual failure was upstream `502`.
- Identified outage condition in GKE:
  - `noetl` service had no ready endpoints.
  - `noetl-server` was in CrashLoop with DB hostname resolution failure (`Name or service not known`).
- Root cause:
  - `POSTGRES_HOST` in `noetl-server-config` had drifted to `postgres.postgres.svc.cluster.local`.
  - Active topology is Cloud SQL via PgBouncer (`pgbouncer.postgres.svc.cluster.local`).
  - Drift happened after running local dev playbook against GKE context.
- Applied runtime recovery in cluster:
  - Patched `noetl-server-config` and `noetl-worker-config` `POSTGRES_HOST=pgbouncer.postgres.svc.cluster.local`.
  - Restarted `noetl-server` and `noetl-worker` deployments.
  - Waited for full rollout and endpoint readiness.
- Verified post-recovery behavior:
  - `noetl-server` + `noetl-worker` healthy.
  - `POST /api/auth/login` now returns expected auth response (`401` for invalid JWT), not `502`.
  - `Access-Control-Allow-Origin: https://mestumre.dev` present on preflight and login responses.
- Prevented recurrence:
  - Updated `repos/ops/automation/development/noetl.yaml` to enforce `expected_kube_context=kind-noetl`.
  - Local playbook now fails fast on non-kind contexts.

## Repos
- `repos/ops`
- `ai-meta`
- Runtime cluster: `gke_noetl-demo-19700101_us-central1_noetl-cluster`

## Related
- Ops commit: `cce555b` (`fix: guard local noetl playbook against non-kind kubectl context`)
