# GKE private GUI deployment profile live

## Summary

- Merged `noetl/ops#20` (`86a15b4`) adding `deploy_gui=false` to the GKE stack playbook.
- Live GKE deploy completed from that change before merge:
  - `noetl-server` and `noetl-worker` run `ghcr.io/noetl/noetl:v2.29.0`.
  - Gateway runs `ghcr.io/noetl/gateway:v2.10.0`.
  - Only `gateway/gateway` is a public LoadBalancer at `34.46.180.136`.
  - `noetl/noetl` remains ClusterIP-only.
  - In-cluster GUI release and `gui` namespace were removed.
- Cloud SQL DDL reapply used the merged event partition guard and skipped attaching `event_2026_gke` when overlapping rows existed in `event_default`.
- Deployment exposed a missing durable NATS consumer after NATS redeploy; PR #20 now ensures `NOETL_COMMANDS/noetl_worker_pool` exists before auth bootstrap dispatches playbooks.
- Gateway CORS preflight from `https://mestumre.dev` succeeds.

## Remaining external step

Deploy GUI to Cloudflare Pages/static hosting with:

```bash
cd repos/gui
npm ci
VITE_API_MODE=gateway \
VITE_API_BASE_URL=https://gateway.mestumre.dev \
VITE_GATEWAY_URL=https://gateway.mestumre.dev \
VITE_ALLOW_SKIP_AUTH=false \
npm run build
npx wrangler pages deploy dist --project-name noetl-gui --branch main
```

Wrangler requires `CLOUDFLARE_API_TOKEN` in this non-interactive shell.

Tags: gke, gateway, cloudflare, private-gke, ops, deployment
