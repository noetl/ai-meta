# 2026-05-11 — GKE parity sync closed AMBER

The GKE parity-sync round restored NoETL server/catalog parity but did not close full GUI parity.

What changed operationally:

- Re-registered `automation/agents/travel/runtime` on GKE, moving it from v5 to v6.
- Re-registered `automation/agents/mcp/amadeus` on GKE, moving it from v3 to v4.
- Re-registered `automation/agents/mcp/vertex-ai` on GKE, moving it from v9 to v10.
- Re-registered `automation/agents/mcp/ollama` on GKE, moving it from v2 to v3.
- Confirmed GKE server/worker are already on `ghcr.io/noetl/noetl:v2.37.8`.

Validation:

- Amadeus MCP `tools/list` completed and reported `tool_count=5` in the `tools_list` event metadata.
- Travel default OpenAI, Anthropic, and Vertex AI help smokes completed with widget renders.
- Ollama smoke completed through fallback to OpenAI because GKE does not have `ollama-bridge` deployed.
- Activities hydration regression completed on GKE: execution `624227210525671975` rendered `render_activities` with 10 items from a 1799-item Amadeus response.

Why AMBER:

- The requested GUI bump to `ghcr.io/noetl/gui:v1.11.0` could not be performed because the GKE cluster has no `gui` / `noetl-gui` Deployment, Service, or Helm release. Only the NoETL server/worker, gateway, and NATS releases were present. The browser-side stale-GUI symptom likely belongs to an external/static GUI deployment path that was not visible in the cluster.

Storage-tier finding:

- GCS is configured in environment variables (`NOETL_GCS_BUCKET=noetl-demo-output`) but is not the active cache tier.
- The active default tier is `kv`; large payloads spill to worker-local disk under `/opt/noetl/data/disk_cache`.
- Router introspection showed `default_cloud_tier=StoreTier.S3`, not GCS.
- `noetl.result_ref` and `noetl.temp_ref` had zero rows during the audit.

Process lesson:

- Local-kind validation rounds need an explicit GKE parity follow-up when the work is intended to be visible in production-like GKE.
- GUI deployment ownership must be explicit; do not assume the GUI image can be bumped through the NoETL Helm release unless a `gui` workload is actually present.
