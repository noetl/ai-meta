# Cloudflare Tunnel for GKE Gateway docs merged
- Timestamp: 2026-04-30T07:06:05Z
- Author: Kadyapam
- Tags: docs,cloudflare,tunnel,gke,gateway

## Summary
Merged noetl/docs#18 at repos/docs 6365986. The production edge runbook now recommends Cloudflare Pages for the GUI and Cloudflare Tunnel to the private GKE Gateway ClusterIP service, rather than Cloud Run. Multiple gateway domains are supported by adding multiple Tunnel public hostnames that point to gateway.gateway.svc.cluster.local:8090, with CORS/Auth0 origins configured per GUI domain.

## Actions
- Fast-forwarded `repos/docs` main after `noetl/docs#18` merged.
- Bumped ai-meta `repos/docs` gitlink to `6365986`.
- Refreshed `memory/current.md` to make Cloudflare Tunnel the active Gateway exposure plan.

## Repos
- `repos/docs`: `6365986`
- `ai-meta`: pending pointer and memory commit

## Related
- `https://github.com/noetl/docs/pull/18`
- `repos/docs/docs/operations/cloudflare-pages-gui-tunnel-gateway.md`
