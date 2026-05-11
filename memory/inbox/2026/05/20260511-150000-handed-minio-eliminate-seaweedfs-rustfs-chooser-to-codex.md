# Handed MinIO elimination + SeaweedFS/RustFS chooser round to Codex

- date: 2026-05-11T15:00:00Z
- tags: infra, object-store, minio-removal, seaweedfs, rustfs, s3-compatible, codex-handoff

## Round goal

MinIO discontinued community-edition support. Eliminate it completely
and replace with a chooser between two S3-compatible alternatives:

- **SeaweedFS** (default) — mature, scale-proven, S3-API-compliant
- **RustFS** (opt-in) — newer, MinIO-API-compatible drop-in

The noetl backend code path doesn't need to change — it's already
backend-agnostic via `NOETL_S3_ENDPOINT`. What changes is deployment
topology and naming in comments/docstrings.

## Architecture

Helm + bootstrap accept `objectStore.kind: seaweedfs | rustfs`. Both
backends expose a canonical Service `object-store.<ns>.svc:9000`. The
noetl-server / noetl-worker pods see the same endpoint URL regardless
of backend. boto3 with custom endpoint already supports this — no S3
client change needed.

Default backend: SeaweedFS. RustFS is opt-in via the chooser.

## Pre-grepped MinIO inventory

repos/ops: 11 files (helm values, setup/bootstrap, setup/destroy,
infrastructure/minio.yaml, ci/kind/config, ci/manifests/noetl/configmaps,
ci/manifests/minio/{namespace,pv,deployment,service}).

repos/noetl: 12 files (mostly comments + docstrings in storage/, plus
configmaps, schema_ddl, playbook.schema.json, config.py, artifact executor,
engine tools).

Codex re-greps in phase 1 to verify completeness.

## Phases (11)

1. Inventory + design pick (verify grep, canonical service name + port)
2. New manifests (seaweedfs + rustfs dirs, delete minio dir)
3. Infrastructure playbooks (object_store.yaml + bootstrap/destroy updates)
4. Helm chart chooser (values + templates)
5. ConfigMap endpoint wiring
6. noetl code comment sweep (functionality unchanged)
7. Docs sweep
8. Smoke kind (both backends, durability test across pod restart)
9. Smoke GKE (identify current S3 endpoint, adapt)
10. PRs (ops + noetl + docs, up to 3)
11. Close out + ai-meta pointer bumps

## Why this round is bigger than recent ones

Most recent rounds were single-PR ops or docs work. This one touches:
- Infrastructure manifests (4 → ~8 new files, 4 deletions)
- Helm chart (values + templates)
- Two playbooks (object_store.yaml new, minio.yaml deleted)
- Setup playbooks (bootstrap + destroy)
- Up to 12 noetl files for comment sweep
- Docs

Up to 3 PRs. Multi-hour round expected. The bridge handoff pattern still
applies — Codex executes autonomously, surfaces blockers cleanly.

## Connects to earlier session findings

- **Path B (storage tier) from round 20260511-110000**: that round found
  router cloud tier was S3 not GCS, with worker-local disk spillover.
  This round addresses the in-cluster S3 backend (MinIO replacement).
  The cloud-tier-router decision (in-cluster S3 vs GCS for durable
  storage) is still separate — name it as deferred follow-up.

- **GKE topology**: GKE may use a remote AWS S3 bucket instead of an
  in-cluster MinIO. Phase 9 identifies which and adapts accordingly.
  Document the distinction (in-cluster object store ≠ cloud-tier router).

## Bridge artefacts

- `bridge/inbox/delegated/20260511-150000-eliminate-minio-add-seaweedfs-rustfs-chooser.task.json`
- `scripts/eliminate_minio_add_seaweedfs_rustfs_chooser_msg.txt`

## Trigger prompt for Codex (paste this in after pushing)

```
MinIO discontinued community-edition support. Eliminate it completely and
add a chooser between SeaweedFS (default, mature) and RustFS (opt-in,
MinIO-API-compatible). Both expose S3-compatible APIs at a canonical
object-store Service. The noetl S3 backend is already endpoint-agnostic,
so swapping backends is a deployment concern — code stays.

Bridge task: bridge/inbox/delegated/20260511-150000-eliminate-minio-add-seaweedfs-rustfs-chooser.task.json
Prompt details: scripts/eliminate_minio_add_seaweedfs_rustfs_chooser_msg.txt
Result file: bridge/outbox/20260511-150000-eliminate-minio-add-seaweedfs-rustfs-chooser.result.json

Run all 11 phases per the bridge task. Discovery-first (phase 1 re-greps
inventory). Up to 3 PRs (ops first, then noetl + docs).

Architectural rules:
  - User explicitly wants MinIO eliminated completely. No fallback.
  - Code path stays as the S3 backend (NOETL_S3_ENDPOINT). Backend-agnostic.
  - StoreTier.S3 enum value stays. Abstract tier name.
  - Default chooser value: seaweedfs. RustFS is opt-in.
  - Don't modify repos/gui or repos/e2e unless inventory surfaces unexpected
    MinIO touchpoints.
  - Don't cut a release.
  - Don't provision new GCP/AWS buckets.
  - No git push from ai-meta.

Smoke matters: phase 8 includes a durability test (kill worker, restart,
verify cached result is retrievable from storage tier) — that's the actual
proof that worker-local-disk-only failure mode is solved by the new
object-store deployment.
```
