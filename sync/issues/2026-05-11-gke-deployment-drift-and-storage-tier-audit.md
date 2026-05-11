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
