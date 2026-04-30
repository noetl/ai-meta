# Cloudflare Pages GUI and Cloud Run Gateway runbook merged
- Timestamp: 2026-04-30T06:37:54Z
- Author: Kadyapam
- Tags: docs,gke,cloudflare,cloud-run,gateway

## Summary
Merged noetl/docs#17 at repos/docs 692f33f. New operations runbook documents the production split: Cloudflare Pages serves https://mestumre.dev, Cloud Run serves https://gateway.mestumre.dev, GKE keeps NoETL server/workers/NATS/PgBouncer private, and the CLOUDFLARE_API_TOKEN should be a scoped API token with Account Cloudflare Pages Edit plus optional Zone DNS Edit for mestumre.dev.

## Actions
- Fast-forwarded `repos/docs` main after `noetl/docs#17` merged.
- Bumped ai-meta `repos/docs` gitlink to `692f33f`.
- Added active memory note for the Cloudflare Pages GUI + Cloud Run Gateway deployment split.

## Repos
- `repos/docs`: `692f33f`
- `ai-meta`: pending pointer and memory commit

## Related
- `https://github.com/noetl/docs/pull/17`
- `repos/docs/docs/operations/cloudflare-pages-gui-cloudrun-gateway.md`
