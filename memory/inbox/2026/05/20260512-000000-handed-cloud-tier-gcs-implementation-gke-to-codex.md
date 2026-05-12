# Handed cloud-tier GCS implementation on GKE to Codex (Round D execution)

- date: 2026-05-12T00:00:00Z
- tags: gke, storage-tier, gcs, round-d-execution, iam-gated, codex-handoff

## Round goal

Execute Round D's recommendation. Move GKE cloud spill tier from S3
(in-cluster SeaweedFS) to GCS (`noetl-demo-output` bucket). Decision is
final; this is implementation.

## What changes

- `NOETL_STORAGE_CLOUD_TIER` flips from `s3` to `gcs` in the GKE worker +
  server ConfigMaps (or helm values, whichever path the team uses).
- The cloud-tier spillover destination becomes GCS via Workload Identity
  on the worker SA (`noetl-worker-mcp@noetl-demo-19700101...`).
- SeaweedFS Service stays in place but is no longer the cloud-tier
  backing — it remains as the local kind / in-cluster object-store path.

## What does NOT change

- Storage router code in `repos/noetl` — unchanged.
- In-cluster object-store chooser (SeaweedFS/RustFS) — unchanged.
- Disk / kv / memory tier defaults — unchanged.
- The GCS bucket — already exists (`noetl-demo-output`).

## The IAM gate

Round D's smoke found `403 storage.buckets.get` for the worker SA on
this bucket. Workload Identity is correctly wired (Vertex AI uses the
same SA in the same way), but no GCS-side binding exists yet.

Recipe Codex documents for Kadyapam if IAM blocks:

```bash
gcloud storage buckets add-iam-policy-binding gs://noetl-demo-output \
  --member=serviceAccount:noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com \
  --role=roles/storage.objectAdmin \
  --project=noetl-demo-19700101
```

If the recipe completes before Codex runs, phase 1 passes and the round
proceeds. If not, AMBER + STOP and the recipe lands in the result file.

## Phases (6)

1. Verify IAM via in-pod `google.cloud.storage` probe.
2. Flip `NOETL_STORAGE_CLOUD_TIER=gcs` in the right config surface.
3. kubectl rollout restart noetl-worker + noetl-server. Verify env.
4. Worker-restart durability test against GCS (etag + content match).
5. Travel agent activities smoke + synthetic large-object spillover if
   activities payload doesn't trigger spill organically.
6. Close out — sync issue, validation log, memory, ops pointer bump.

## Cap

0-1 ops PRs depending on which config surface needs the flip. AMBER if
IAM not granted.

## Bridge artefacts

- `bridge/inbox/delegated/20260512-000000-cloud-tier-gcs-implementation-gke.task.json`
- `scripts/cloud_tier_gcs_implementation_gke_msg.txt`

## Trigger prompt for Codex (paste this in after pushing)

```
Execute Round D's recommendation. Flip GKE cloud spill tier from S3 to
GCS. Bucket noetl-demo-output already exists. Worker SA Workload Identity
is wired. The Round D smoke found 403 on the bucket — IAM binding is the
only gate.

Bridge task: bridge/inbox/delegated/20260512-000000-cloud-tier-gcs-implementation-gke.task.json
Prompt details: scripts/cloud_tier_gcs_implementation_gke_msg.txt
Result file: bridge/outbox/20260512-000000-cloud-tier-gcs-implementation-gke.result.json
Decision doc context: sync/issues/2026-05-11-cloud-tier-router-decision.md

Run all 6 phases per the bridge task:
  1. Verify IAM via google.cloud.storage probe inside worker pod.
     If 403 → AMBER + STOP with IAM recipe.
  2. Flip NOETL_STORAGE_CLOUD_TIER=gcs.
  3. Rollout restart worker + server.
  4. Worker-restart durability test (etag + content match).
  5. Travel activities smoke + synthetic large-object if needed.
  6. Close out.

Architectural rules:
  - GCS as cloud tier only. Don't touch SeaweedFS or router code.
  - Don't grant IAM yourself — Kadyapam owns.
  - No release cut. No git push from ai-meta.

If IAM not granted: AMBER + STOP, document the gcloud binding recipe
for Kadyapam, no rollout. Either outcome (GREEN or AMBER+IAM-pending)
is acceptable for this round.
```

## After this lands

Two of three remaining follow-ups complete:
- ✅ Round D recommendation implemented (or AMBER pending IAM)
- ⏳ Ollama backend provisioning on GKE (Round B option B promotion)
- ⏳ Amadeus production credentials provisioning (Round C unblocking)

Both remaining ones are user-action-gated. Pure implementation rounds
ready when wanted.
