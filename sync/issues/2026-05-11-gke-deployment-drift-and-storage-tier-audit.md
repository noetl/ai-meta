# GKE Deployment Drift And Storage Tier Audit

Date: 2026-05-11

## Summary

This round audited and repaired the GKE NoETL server/catalog side after the travel-agent flagship work had been validated mainly on local kind. The GKE server and worker were already on `ghcr.io/noetl/noetl:v2.37.8`, but the catalog entries for the travel runtime and MCP playbooks were stale relative to kind.

The four playbooks were re-registered on GKE:

| Playbook | GKE before | GKE after |
| --- | ---: | ---: |
| `automation/agents/travel/runtime` | v5 | v6 |
| `automation/agents/mcp/amadeus` | v3 | v4 |
| `automation/agents/mcp/vertex-ai` | v9 | v10 |
| `automation/agents/mcp/ollama` | v2 | v3 |

No product-code changes or releases were made in this round.

## Smoke Results

Headless GKE API smoke was run through `kubectl port-forward svc/noetl 18082:8082`. This is equivalent to the gateway terminal's backend path, but not a GUI browser smoke.

| Check | Execution | Result |
| --- | --- | --- |
| Amadeus MCP tools/list | `624226011525153600` | `COMPLETED`; `tool_count=5` in the `tools_list` event metadata |
| `travel help` default provider | `624226042370065269` | `COMPLETED`; `effective_provider=openai`; widget render present |
| `travel flights SFO JFK 2026-07-15` | `624226093230195658` | `COMPLETED`; friendly Amadeus failure widget rendered |
| `travel --provider anthropic help` | `624226455399956580` | `COMPLETED`; `effective_provider=anthropic`; no fallback |
| `travel --provider vertex-ai help` | `624226849547092275` | `COMPLETED`; `effective_provider=vertex-ai`; no fallback |
| `travel --provider ollama help` | `624227159959142829` | `COMPLETED`; fell back to OpenAI because `ollama-bridge` is absent on GKE |
| Activities hydration regression | `624227210525671975` | `COMPLETED`; `render_activities`; 10 rendered items from a 1799-item Amadeus response |

The item #11 engine fix is working on GKE: the activities path no longer loses the child MCP result when the child payload is large.

## GUI Drift Finding

The requested GUI image bump to `ghcr.io/noetl/gui:v1.11.0` could not be applied on GKE because the cluster has no `gui` or `noetl-gui` Deployment, Service, or Helm release. The GKE Helm releases observed were:

- `nats/nats`
- `noetl/noetl`
- `gateway/noetl-gateway`

The GKE workload images observed were:

- `noetl/noetl-server`: `ghcr.io/noetl/noetl:v2.37.8`
- `noetl/noetl-worker`: `ghcr.io/noetl/noetl:v2.37.8`
- `gateway/gateway`: `ghcr.io/noetl/gateway:v2.10.0`

That means the stale-GUI symptoms reported from the browser, such as `travel` being an unknown command, are likely coming from a GUI deployment path outside this cluster's NoETL Helm release. The next parity round needs an explicit owner/path for the GUI asset deployment, or a separate infra decision to restore an in-cluster GUI deployment.

## Storage Tier Answer

Short answer: GCS is configured but it is not the active cache tier.

The GKE worker environment includes:

```text
NOETL_DEFAULT_STORAGE_TIER=kv
NOETL_STORAGE_CLOUD_TIER=s3
NOETL_GCS_BUCKET=noetl-demo-output
NOETL_GCS_PREFIX=results/
NOETL_STORAGE_LOCAL_CACHE_DIR=/opt/noetl/data/disk_cache
```

Runtime introspection showed:

- `default_store` is `TempStore`.
- `default_router` is `StorageRouter`.
- Router `default_cloud_tier` is `StoreTier.S3`.
- Router `kv_max` is `1048576`.
- Available tiers include `gcs`, but it is not selected by the current configuration.

The active large-payload behavior is worker-local disk spillover. One worker pod had a `1.3M` file under `/opt/noetl/data/disk_cache`; the other had none. No volume mounts were observed on the worker pods, so this cache is pod-local ephemeral rather than shared storage.

The Postgres metadata tables were empty:

```text
noetl.result_ref rows = 0
noetl.temp_ref rows = 0
```

For the travel activities path, this is acceptable after item #11 because the parent agent call now receives a bounded terminal result/control payload instead of depending on cross-pod full-result rehydration from disk.

## Open Items

1. Define the GKE GUI deployment path.
   The backend catalog is current, but there is no in-cluster GUI to bump to `v1.11.0`.

2. Decide whether GKE should run `ollama-bridge`.
   The Ollama MCP playbook is registered, but the provider falls back to OpenAI because the bridge service is absent.

3. Decide whether object-storage-backed result cache is required.
   If cross-pod full-result rehydration is a product requirement, configure GCS deliberately instead of relying on pod-local disk. Do not assume `NOETL_GCS_BUCKET` alone makes GCS the active cache tier.

4. Chain GKE parity after local-kind rounds.
   Future rounds that deploy catalog or GUI changes to kind should explicitly include a GKE parity follow-up, or record why GKE is intentionally deferred.

## Result

GKE NoETL server/catalog parity is restored. Overall round status is AMBER because GUI parity remains unresolved outside the observed GKE Helm/deployment surface.

## Follow-Up: Gateway Terminal Surface Trace

Date: 2026-05-11

Path A traced the missing GUI surface. The gateway terminal page is served from Cloudflare Pages at `https://mestumre.dev`; it is not backed by an in-cluster `gui` / `noetl-gui` Deployment. The API path is `https://gateway.mestumre.dev`, which routes through the GKE `gateway` namespace and the `cloudflare/noetl-gke-gateway-tunnel` deployment.

Evidence:

- `https://mestumre.dev` returns a Vite SPA shell with Cloudflare headers and assets such as `/assets/index-Db6acc8T.js`.
- The browser resolves to `https://mestumre.dev/login` and shows the Gateway Login page.
- `repos/ops/automation/cloudflare/gke_gateway_edge.yaml` declares:
  - `pages_project_name: noetl-gui`
  - `pages_branch: main`
  - `gui_domain: mestumre.dev`
  - `gateway_public_url: https://gateway.mestumre.dev`
  - `gateway_hostname: gateway.mestumre.dev`
- GKE has `cloudflare/noetl-gke-gateway-tunnel` running 2/2 and `gateway/gateway` running `ghcr.io/noetl/gateway:v2.10.0`.

The bump mechanism is the existing ops playbook:

```bash
cd repos/ops
export CLOUDFLARE_API_TOKEN=<scoped token>
noetl run automation/cloudflare/gke_gateway_edge.yaml \
  --runtime local \
  --set action=pages \
  --set gui_repo_dir=../gui \
  --set pages_project_name=noetl-gui \
  --set pages_branch=main \
  --set gui_domain=mestumre.dev \
  --set gateway_public_url=https://gateway.mestumre.dev
```

The playbook runs `npm ci`, builds `repos/gui` with `VITE_API_MODE=gateway`, `VITE_GATEWAY_URL=https://gateway.mestumre.dev`, and deploys the `dist` directory with `wrangler pages deploy`.

This follow-up also closed AMBER: `CLOUDFLARE_API_TOKEN` was not present in the environment, and `wrangler pages project list` failed because non-interactive Wrangler requires that token. No Cloudflare project, DNS, tunnel, or Pages deployment was changed.

Current conclusion:

- The GKE backend/catalog drift is fixed.
- The GUI drift is now precisely located: Cloudflare Pages project `noetl-gui`.
- The next action is a credentialed Cloudflare Pages deploy using the existing playbook. Kadyapam owns provisioning/exporting the scoped Cloudflare token; do not store it in ai-meta.

## Follow-Up: MinIO Elimination And Object-Store Chooser

Date: 2026-05-11

The storage-tier follow-up eliminated MinIO from merged ops/docs product sources and introduced an S3-compatible object-store chooser. The noetl-side wording/static-manifest cleanup is open in `noetl/noetl#430`; CI passed, but review is required, so ai-meta intentionally still points `repos/noetl` at main until that PR lands.

- `objectStore.kind: seaweedfs | rustfs`
- default backend: `seaweedfs`
- opt-in backend: `rustfs`
- canonical Service: `object-store.object-store.svc:9000`
- abstract runtime tier remains `StoreTier.S3`

PR state:

- `noetl/ops#70` merged. It removes the MinIO playbook/manifests, adds SeaweedFS and RustFS raw manifests, adds Helm templates/values for `objectStore.kind`, and points local NoETL config at the canonical object-store endpoint.
- `noetl/docs#60` merged. It replaces the MinIO development page with object-store docs and updates storage reference wording.
- `noetl/noetl#430` is open. CI passed, but branch protection requires review, so ai-meta did not bump the noetl submodule pointer.

Local kind proof:

- SeaweedFS deployed and passed S3 bucket create / object upload / object download through `object-store:9000`.
- The object survived SeaweedFS pod deletion/restart.
- RustFS deployed after adding a writable `/logs` volume and an initContainer that fixes UID 10001 permissions on `/data` and `/logs`; it passed the same S3 smoke.
- The local cluster was returned to default SeaweedFS.
- NoETL server and worker configmaps were updated locally with `NOETL_S3_ENDPOINT=http://object-store.object-store.svc.cluster.local:9000`, bucket `noetl`, `NOETL_STORAGE_CLOUD_TIER=s3`, and restarted.
- A worker-pod boto3 put/get survived deletion/restart of all NoETL worker pods, proving the object-store service is durable beyond worker-local disk.

Remaining GKE work:

1. Review and merge `noetl/noetl#430`, then bump the noetl pointer in ai-meta.
2. Run the GKE smart-adapt phase only after pointers are aligned. If GKE's S3 tier is an in-cluster MinIO service, replace it with the new object-store deployment. If it is a remote AWS bucket or another managed S3-compatible endpoint, do not replace it.
3. Run a true NoETL large-payload execution that spills through the ResultHandler/DISK async spill path, kill worker pods, and verify report/status rehydrates from object storage.

Round status: AMBER. The local deployment and backend chooser are validated, but the noetl PR is review-blocked and GKE replacement was deferred until merged state is complete.

## Follow-Up: Object-Store Chooser GKE Rollout

Date: 2026-05-11

`noetl/noetl#430` merged, so the MinIO-elimination AMBER is closed for the NoETL engine pointer and GKE rollout path. ai-meta now points `repos/noetl` at post-#430 main (`19eafd89e50c8a6fdb9d0f789866942667dbdf3f`, ai-meta commit `d09b6c1`).

GKE inspection found the cluster in case (a): NoETL was configured for a stale in-cluster MinIO endpoint, not remote AWS S3 and not an existing chooser deployment.

```text
worker NOETL_S3_ENDPOINT=http://minio.minio.svc.cluster.local:9000
worker NOETL_S3_BUCKET=noetl-results
worker NOETL_STORAGE_CLOUD_TIER=s3
```

No visible MinIO workload or object-store Service existed before the rollout. The Helm chooser was enabled with SeaweedFS as the default backend:

```text
object-store/object-store Service -> 9000
object-store/seaweedfs image=chrislusf/seaweedfs:3.97
PVC object-store-data size=50Gi
```

NoETL server and worker now read:

```text
NOETL_S3_ENDPOINT=http://object-store.object-store.svc.cluster.local:9000
NOETL_S3_BUCKET=noetl
NOETL_STORAGE_CLOUD_TIER=s3
```

Because the endpoint change is delivered through ConfigMaps, server and worker needed explicit rollout restarts before pod environments reflected the new values.

Durability proof passed: a worker wrote `smoke/gke-object-store-durability-20260512T011442Z.txt` to SeaweedFS, then `deployment/noetl-worker` was restarted. The restarted worker fetched the same object with ETag `33067294b42a79290bb83f8f06f2e48c` and SHA-256 `f2da5c239fb1ecaae06bc6f1cc9e4425bb93e8c90ca109dbe27dd9a4d7f317f8`.

Travel activities smoke also passed on GKE:

| Check | Execution | Result |
| --- | --- | --- |
| `travel --provider openai activities near Times Square` | `624795118960115887` | `COMPLETED`; child `624795172798202107`; `render_activities`; `app:column`; `10` rendered items; `activities_total=1799` |

The `travel_agent_events` table in the `pg_k8s` target database contains both the `classify_intent` and `render_activities` audit rows for the execution. The render row records `ai_provider=openai`, `intent=activities`, `render_type=app:column`, `envelope_ok=true`, and `envelope_total=10`.

The item #11 engine fix is still doing the right work after the object-store rollout: the worker logged a local disk-cache miss for the child result reference, then recovered the bounded child data through the terminal-event/control-data path and rendered the parent widget. In other words, object-store durability is now present for the configured S3 backend, and the agent-result hydration fallback is still the immediate correctness path for this travel activities execution.

Round status: GREEN with one note. Backend/API evidence is complete, but no Cloudflare GUI screenshot was captured because the available browser surface was `https://mestumre.dev/login`.

## Follow-Up: Ollama Bridge On GKE, Option A

Date: 2026-05-11

Option A was selected explicitly: deploy `ollama-bridge` to GKE without an Ollama backend. This is a routing placeholder, not a native Ollama inference deployment.

The Helm-managed bridge is now live:

```text
namespace: noetl
deployment: ollama-bridge
image: ghcr.io/noetl/noetl:v2.37.8
service: ollama-bridge.noetl.svc.cluster.local:8765
OLLAMA_URL=http://ollama.noetl.svc.cluster.local:11434
```

No `ollama` backend Service exists, by design for option A.

Routing proof:

- A NoETL worker pod successfully called `http://ollama-bridge.noetl.svc.cluster.local:8765/jsonrpc`.
- `tools/list` returned HTTP 200 with the bridge tool catalog.
- Bridge logs showed `POST /jsonrpc HTTP/1.1 200 OK` from the worker/source pods.

Travel smoke:

| Check | Execution | Result |
| --- | --- | --- |
| `travel --provider ollama help` | `624832446000792195` | `COMPLETED`; rendered `app:column`; expected fallback to `effective_provider=openai`; fallback reason says the bridge could not connect to `ollama.noetl.svc.cluster.local:11434` |

This closes the earlier "bridge service absent" part of the Ollama-on-GKE item. The remaining item is backend provisioning: either deploy a CPU Ollama pod or point the bridge at an external Ollama endpoint when real `effective_provider=ollama` inference is needed.
