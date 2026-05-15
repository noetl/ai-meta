# Colima Migration + Envelope Validator Fix Deployed
- Timestamp: 2026-04-17T03:42:44Z
- Author: Kadyapam
- Tags: noetl,ops,colima,docker,kind,deployment,bugfix,envelope-validator,test-pft-flow

## Summary

Migrated local development runtime from Docker Desktop to Colima on external SSD (`/Volumes/X10/colima-home`). Diagnosed and fixed a deployment-blocking bug where the server rejected every worker `call.done` event with `payload.result includes unsupported keys: meta`. Rebuilt the full kind cluster on Colima and validated `test_pft_flow` end-to-end — execution `606748093614129296` completed 69 events through all steps with zero server 500s and zero statement timeouts.

## Envelope Validator Bug (noetl `18d80457`)

**Root cause:** Follow-up commit `6c1e2c09` (persist_before_emit middleware wiring) added `envelope.setdefault("meta", {})["envelope_path"] = "inline"` inside `_build_strict_result_envelope` — the legacy envelope path that runs even with `NOETL_REFERENCE_ENVELOPE_V3=false`. This placed a `meta` key inside `event.result`, which collided with the server's `_STRICT_RESULT_ALLOWED_KEYS = {"status", "reference", "context", "command_id"}`. Every worker terminal event (call.done, call.error) was 500'd at ingest, stalling all executions immediately after the start step.

**Fix (noetl `18d80457`):**
1. Server: added `"meta"` and `"parent_ref"` to `_STRICT_RESULT_ALLOWED_KEYS` in `noetl/server/api/core/core.py`.
2. Worker: removed `result.meta` annotation from legacy envelope builder; `envelope_path` is added to event-level meta by the caller in `_execute_command`.
3. Test: updated `test_legacy_result_does_not_carry_meta_in_envelope` to assert `"meta" not in result_envelope`.

## Colima Migration

**Docker Desktop:** stopped and `/usr/local/bin/docker` symlink removed (was v24, API 1.43 — incompatible with Colima's Docker engine v29.2.1 requiring API ≥ 1.44).

**Colima setup:**
- `COLIMA_HOME=/Volumes/X10/colima-home` (persisted in `~/.zshrc`)
- VM type: `vz` (macOS Virtualization.Framework)
- Resources: 6 CPU, 12 GB RAM, 200 GB disk on external SSD
- Docker CLI: Homebrew v29.4.0 at `/opt/homebrew/bin/docker` + shim at `/Volumes/X10/dev/cargo/bin/docker`
- Buildx: Homebrew v0.33.0 (replaced Docker Desktop's v0.11.0 in `~/.docker/cli-plugins/`)
- `~/.docker/config.json`: `credsStore` changed from `desktop` to `osxkeychain`; added `cliPluginsExtraDirs`

**Ops guard fix (ops `0570b56`):** `colima status` check in `noetl.yaml` and `kind.yaml` updated from `awk -F': *' '/^Status:/'` (broken on v0.10+ log-style output) to `grep -qi "is running"`.

## Kind Cluster on Colima

- Fresh `kind-noetl` cluster created
- All infra deployed: postgres (17.4), nats, test-server (paginated API), noetl server + 3 workers
- Image loading: `DOCKER_BUILDKIT=0` required for `kind load` compatibility with Colima; `docker.io/library/` prefix used for `ctr` import
- `NOETL_SHARD_COUNT=2`, `NOETL_CHECKPOINT_INTERVAL_MS=5000` for local dev resource budget
- 143 playbooks registered
- Phase A–F DDL applied to database (trigger dropped, projection_checkpoint/execution_shard/checkpoint/compactor_state tables created)

## Validation

Execution `606748093614129296` (`test_pft_flow`):
- 69 events processed, all steps traversed: `start` → `setup_facility_work` → `load_next_facility` → data type loops → `check_results` → `end`
- `check_results` → `call.error` (expected: patient count assertion failure — the pre-existing AHM-4280..4284 race condition, not a runtime bug)
- Zero server 500 errors in logs
- Zero statement timeout errors (the trigger contention bug that motivated Phase A is confirmed fixed)
- Execution completed in ~15 seconds (vs 18+ minute stall before the fix)

## Commits

| Repo | SHA | Message |
|---|---|---|
| noetl | `18d80457` | `fix(server): accept meta + parent_ref in strict result envelope validator` |
| ops | `0570b56` | `fix(ops): update colima status check for v0.10+ log-style output` |
| ai-meta | (this commit) | pointer bumps + this memory entry |

## Remaining

- `test_pft_flow` `check_results` assertion failure is the pre-existing patient-loss race (AHM-4280..4284) — unrelated to the architecture redesign
- Ops playbook `kind.yaml` `create` action needs testing on the fresh Colima setup (used manual kubectl for this session)
- `noetl.yaml` `redeploy` action needs the `DOCKER_BUILDKIT=0` workaround for image loading into kind on Colima — consider adding to the playbook
- Port-forward `kubectl -n noetl port-forward svc/noetl 8082:8082` required since NodePort may not map to localhost on Colima (unlike Docker Desktop)

## Repos

- repos/noetl `18d80457` — fix(server): accept meta + parent_ref in strict result envelope validator
- repos/ops `0570b56` — fix(ops): update colima status check for v0.10+ log-style output

## Related

- Prior memory: `20260416-065402-noetl-async-sharded-redesign.md` (Phase A-F landing)
- Prior memory: `20260416-142730-noetl-async-sharded-followups-completed.md` (middleware wiring + async getters)
- Design doc: `repos/docs/docs/features/noetl_async_sharded_architecture.md`
