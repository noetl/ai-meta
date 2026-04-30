# Cloudflare GKE edge deployment playbook merged
- Timestamp: 2026-04-30T15:00:30Z
- Author: Kadyapam
- Tags: ops,cloudflare,tunnel,gke,gateway,gui

## Summary
Merged noetl/ops#21 at repos/ops e26da23. Added automation/cloudflare/gke_gateway_edge.yaml local-runtime playbook to deploy the GUI to Cloudflare Pages and expose the private GKE Gateway ClusterIP service through Cloudflare Tunnel, with support for multiple gateway hostnames. Deploy requires a rotated CLOUDFLARE_API_TOKEN exported locally; do not store token values in repos or chat.

## Actions
- Fast-forwarded `repos/ops` main after `noetl/ops#21` merged.
- Bumped ai-meta `repos/ops` gitlink to `e26da23`.
- Updated `memory/current.md` with the Cloudflare Pages + Tunnel playbook deployment path.

## Repos
- `repos/ops`: `e26da23`
- `ai-meta`: pending pointer and memory commit

## Related
- `https://github.com/noetl/ops/pull/21`
- `repos/ops/automation/cloudflare/gke_gateway_edge.yaml`
