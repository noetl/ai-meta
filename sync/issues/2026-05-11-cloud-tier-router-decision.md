# Cloud-tier router decision

Date: 2026-05-11
Status: decision ready; implementation deferred

## Decision

Use **GCS as the GKE production cloud spill tier** once bucket IAM is granted to the worker service account.

Keep the in-cluster S3-compatible object store, currently SeaweedFS, as the local/kind default and as the GKE in-cluster object-store backend where pod-restart durability is enough. Do not introduce remote AWS S3 for the GCP deployment unless a future cross-cloud requirement appears.

This is a design decision only. No router code, Helm values, buckets, or IAM bindings were changed in this round.

## Current GKE State

GKE context:

```text
gke_noetl-demo-19700101_us-central1_noetl-cluster
namespace=noetl
```

Worker storage env:

```text
NOETL_DEFAULT_STORAGE_TIER=kv
NOETL_STORAGE_CLOUD_TIER=s3
NOETL_S3_ENDPOINT=http://object-store.object-store.svc.cluster.local:9000
NOETL_S3_BUCKET=noetl
NOETL_S3_REGION=us-east-1
NOETL_GCS_BUCKET=noetl-demo-output
NOETL_GCS_PREFIX=results/
NOETL_STORAGE_LOCAL_CACHE_DIR=/opt/noetl/data/disk_cache
```

Router/runtime introspection from inside `deploy/noetl-worker`:

```text
StoreTier=memory,kv,disk,s3,gcs,db,duckdb,eventlog
ResultHandler.default_tier=kv
Router.default_cloud_tier=s3
select_512k_auto=kv
select_2mb_auto=disk
default_store_class=TempStore
```

The result handler keeps small results in KV and routes `>= 1 MB` results to `disk`. The disk backend is wired with the configured cloud tier. On GKE today, that cloud tier is S3-compatible SeaweedFS through `object-store.object-store.svc.cluster.local:9000`.

The worker Kubernetes service account uses Workload Identity:

```text
noetl/noetl-worker -> noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com
```

That Google service account currently has project roles for AI and cluster inspection, not storage:

```text
roles/aiplatform.user
roles/container.viewer
roles/mcp.toolUser
```

GCS bucket `noetl-demo-output` exists, but a read-only bucket metadata probe from inside the worker returned:

```text
403: noetl-worker-mcp@noetl-demo-19700101.iam.gserviceaccount.com does not have storage.buckets.get access
```

So GCS is configured by env, but not usable by the worker yet.

## Workload Analysis

The `travel_agent_events` table was not present in the queried GKE database, so this round used `noetl.event` plus storage reference metadata as the durable source of evidence.

Reference tables:

```text
noetl.temp_ref rows: 0
noetl.result_ref rows: 0
```

Event scan over the last 7 days:

```text
total_events=216249
events containing temp_ref/result_ref markers=8933
events with embedded "bytes" metadata=8621
p50 bytes=1123
p95 bytes=9527
avg bytes=8060
max bytes=1249108
```

Largest known spillover shape:

```text
node_name=amadeus_search_activities
event_type=command.completed / step.exit / call.done
rows=9
avg bytes=1240126
max bytes=1249108
```

Current worker local disk cache:

```text
/opt/noetl/data/disk_cache files=1
size=1249029 bytes
```

Interpretation:

- Spillover is real, but currently rare and modest.
- The known maximum is the Amadeus activities MCP result at about 1.25 MB.
- Most references are control-plane sized, with p95 under 10 KB.
- Cost is not the deciding factor at current volumes.
- The deciding factor is the durability boundary: pod restart, cluster recreation, or cross-region/cross-cluster recovery.

## Option Matrix

| Option | Cost | Complexity | Durability | Cross-region / cross-cluster | Ops burden | Fit |
| --- | --- | --- | --- | --- | --- | --- |
| GCS | Low at current spillover volume | Medium: bucket IAM + env flip | High, managed object storage | Strong within GCP; bucket can be regional, dual-region, or multi-region | Low after IAM is correct | Best production cloud tier |
| In-cluster S3 / SeaweedFS | Lowest incremental cost; already deployed | Low: already live | Good for pod restarts; depends on PVC and cluster lifecycle | Weak; not a DR tier | Medium: operate StatefulSet/PVC | Best local/kind and in-cluster cache |
| Remote AWS S3 | Low storage cost but cross-cloud egress and credentials | High: AWS IAM in a GCP deployment | High | Strong if explicitly cross-cloud | High: cross-cloud auth, billing, incident surface | Not justified today |

## Recommendation

For GKE production, use **GCS** as the durable cloud tier for spillover.

Rationale:

- NoETL is already running on GKE in project `noetl-demo-19700101`.
- Workload Identity is already the accepted credential pattern for Vertex AI and Secret Manager.
- A GCS bucket already exists (`noetl-demo-output`), so the missing piece is IAM and an explicit router flip.
- Current spillover volume is small enough that GCS cost should be negligible compared with operational clarity.
- SeaweedFS remains valuable, but it should be treated as in-cluster durability, not disaster recovery.
- Remote AWS S3 adds cross-cloud egress and credential complexity without a current requirement.

## Implementation Sketch

Follow-up implementation round, not this round:

1. Grant the worker service account least-privilege access to `gs://noetl-demo-output`.
   - Required capabilities: bucket metadata read plus object create/read/delete/list under the configured prefix.
   - Practical bucket-level binding: object read/write/delete role plus bucket metadata read, or a custom role containing `storage.buckets.get` and required `storage.objects.*` permissions.
2. Flip GKE worker/server env:

```text
NOETL_STORAGE_CLOUD_TIER=gcs
NOETL_GCS_BUCKET=noetl-demo-output
NOETL_GCS_PREFIX=results/
```

3. Keep the SeaweedFS object-store deployment in place for local/kind parity and any in-cluster S3-compatible use cases.
4. Restart NoETL server/worker.
5. Run a forced large-result smoke:
   - create a result over 1 MB,
   - confirm `Router.default_cloud_tier=gcs`,
   - confirm GCS object creation under `gs://noetl-demo-output/results/`,
   - restart workers,
   - verify the result hydrates from GCS.
6. Run the known travel activities regression once.

## Migration Plan

This can be zero-downtime for new writes:

1. Grant IAM first.
2. Deploy env flip during a low-traffic window.
3. Restart workers and server.
4. Validate new large writes land in GCS.
5. Leave existing SeaweedFS objects untouched until natural expiry or a separate migration/cleanup round.

Do not attempt to rewrite existing object-store blobs in the same round. The current evidence suggests they are operational validation artifacts, not a large production corpus.

## Deferred Follow-Up

Implementation round: "GKE storage cloud tier to GCS".

Scope:

- IAM/bucket access verification.
- Helm/env flip to `NOETL_STORAGE_CLOUD_TIER=gcs`.
- Large-result durability smoke.
- Travel activities smoke.
- Documentation of fallback/rollback to `s3` if GCS access fails.
