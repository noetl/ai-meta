# #96 Rust system worker pool live: scheduled cleanup + Python-era legacy removed

**Date:** 2026-06-14
**Issue:** noetl/ai-meta#96 (CLOSED — goal met)
**Follow-up:** noetl/ai-meta#97 (remaining entangled Python-deploy refactor)

## What shipped
Rust-native system worker pool deployed to prod, first job = scheduled
retention/cleanup of transient `noetl.*` tables.

- **server#193** (v3.6.0, prod `server-rust:v3.5.4` `sha256:2bb06d5a…`) —
  `POST /api/internal/cleanup/purge`, service-account-gated. Purges terminal
  `noetl.command` rows (`completed_at` < N days, default 7) + dead
  `noetl.runtime` worker_pool registrations (heartbeat < N min, default 60).
  `noetl.event` retention is OPT-IN, default 0 = never (append-only source of
  truth; purging breaks replay). Span + `noetl_cleanup_rows_purged_total{table}`
  metric + structured log. Code: `services/internal.rs::purge_stale`,
  `handlers/internal.rs::cleanup_purge`.
- **ops#185** — `playbooks/system/scheduled_cleanup.yaml` (calls the endpoint
  via the system pool, bearer `NOETL_INTERNAL_API_TOKEN`),
  `worker-system-pool-deployment-prod.yaml` (Rust image, `NOETL_COMMANDS_RUST`
  stream, consumer `noetl_worker_system_rust`, filter `noetl.commands.system.>`),
  `cronjob-scheduled-cleanup.yaml` (hourly `POST /api/execute path=system/scheduled_cleanup`).
- Pointers: server@9f399f7 + ops@7b02727.

## Durable architecture facts
- **The Rust server bypasses the transactional outbox.** It publishes command
  notifications directly to NATS JetStream (`execute.rs:1163`) and writes events
  inline via `/api/events`. Nothing writes `noetl.outbox`. So the Python-era
  `system/outbox_publisher` + `system/projector` playbooks are OBSOLETE — the
  system pool's real job is cleanup, not outbox draining.
- **Pool routing**: `system/*` playbook paths → `noetl.commands.system.<eid>`
  (`execute.rs:1129`); only the system pool consumes that filter. Path prefix is
  the trigger.
- **System-pool bearer auth**: the worker lifts `NOETL_INTERNAL_API_TOKEN` from
  pod env into `ctx.secrets` via `NOETL_KEYCHAIN_ENV_VARS`; playbooks reference
  `auth: { type: bearer, credential: NOETL_INTERNAL_API_TOKEN }`.
- **Terminal playbook steps need a `tool`** — the parser rejects a bare
  `- step: end`. Give it `tool: { kind: python, code: 'result={"status":"complete"}' }`.

## Prod is now Rust-only
Deleted the dead prod `noetl-server` + `noetl-worker` Python deployments
(orphaned — the `noetl` Service selects `app: noetl-server-rust`; gateway health
stayed 200). Prod runs: noetl-server-rust + noetl-worker-rust + noetl-worker-
system-pool, plus the hourly cleanup CronJob.

## Still open (#97 — entangled Python-deploy refactor)
- ci/manifests Python manifests: `server-deployment`, `worker-deployment`,
  `subscription-runtime-deployment`, `configmap-server/worker`, `worker-metrics-service`.
- `automation/development/noetl.yaml` hardcodes `rollout status deployment/noetl-server`
  + `noetl-worker` (Python names) and globs `*-prod.yaml` without filtering →
  needs Rust-ification before those manifests can be deleted.
- **Stale helm release** `noetl` rev 185 (2026-05-29, pre-cutover). A `helm
  upgrade` against the current chart would revert prod to Python — retire or
  rewrite the chart for the Rust stack.
