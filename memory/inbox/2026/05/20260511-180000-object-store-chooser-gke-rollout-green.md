# Object-store chooser GKE rollout GREEN

Date: 2026-05-11

The MinIO-elimination AMBER is closed on GKE after `noetl/noetl#430` merged. ai-meta now points `repos/noetl` at post-#430 main (`19eafd89e50c8a6fdb9d0f789866942667dbdf3f`, commit `d09b6c1` in ai-meta).

GKE inspection found case (a): the NoETL worker was still configured with the stale in-cluster MinIO endpoint `http://minio.minio.svc.cluster.local:9000`, while no MinIO workload or object-store Service was visible. The Helm chooser was deployed with the default SeaweedFS backend:

- namespace: `object-store`
- Service: `object-store.object-store.svc.cluster.local:9000`
- Deployment: `seaweedfs`
- image: `chrislusf/seaweedfs:3.97`
- PVC: `object-store-data`, `50Gi`

NoETL server and worker ConfigMaps now point at:

- `NOETL_S3_ENDPOINT=http://object-store.object-store.svc.cluster.local:9000`
- `NOETL_S3_BUCKET=noetl`
- `NOETL_STORAGE_CLOUD_TIER=s3`

ConfigMap-only changes did not restart pods automatically, so server and worker were explicitly restarted. After the terminating old worker disappeared, `kubectl exec deploy/noetl-worker -- env` showed the canonical object-store endpoint.

Durability proof passed on GKE. A boto3 PUT/GET from inside the worker wrote `smoke/gke-object-store-durability-20260512T011442Z.txt` to bucket `noetl` with ETag `33067294b42a79290bb83f8f06f2e48c` and SHA-256 `f2da5c239fb1ecaae06bc6f1cc9e4425bb93e8c90ca109dbe27dd9a4d7f317f8`. After `kubectl rollout restart deployment/noetl-worker`, the restarted worker fetched the same object with the same ETag and checksum.

Travel activities smoke also passed on GKE. Execution `624795118960115887` for `activities near Times Square` completed with `effective_provider=openai`, `intent=activities`, child execution `624795172798202107`, and `render_activities` produced an `app:column` widget summarizing `10 activities found near (40.758, -73.9855)`. The child Amadeus MCP response carried `data.ok=true`, `items_len=10`, and `_meta.activities_total=1799`.

The post-#430 engine behavior was observed directly: the worker logged a local disk-cache miss for the large child result reference, then the agent executor still produced an inline parent result of about 45 KB using the terminal-event/control-data fallback. That is the intended fix for the item #11 hydration bug.

Audit rows exist in the `pg_k8s` credential target database: `classify_intent` and `render_activities`, both with `ai_provider=openai` and `intent=activities`; the render row has `render_type=app:column`, `envelope_ok=true`, and `envelope_total=10`.

One note: no Cloudflare GUI screenshot was captured in this backend rollout round because the current browser surface was `https://mestumre.dev/login`. Backend/API proof is complete; GUI-auth screenshotting remains separate from the object-store rollout.

Result file: `bridge/outbox/20260511-180000-object-store-chooser-gke-rollout.result.json`.
