# NoETL v2.10.10 rolled out to GKE and project org note
- Timestamp: 2026-03-18T04:35:15Z
- Author: Kadyapam
- Tags: gke,deployment,release,v2.10.10,ai-meta,submodules,adiona,project-context

## Summary
Deployed ghcr.io/noetl/noetl:v2.10.10 to gke_noetl-demo-19700101_us-central1_noetl-cluster via repos/ops automation/gcp_gke/noetl_gke_fresh_stack.yaml with Cloud SQL + PgBouncer + static LB profile for mestumre.dev. Verified noetl-server and noetl-worker now run v2.10.10 and are Ready. Refreshed ai-meta with git pull (fast-forward) and executed required submodule sync/update from repo root. Context note: Google Cloud project noetl-demo-19700101 is operated under adiona.org organization context; reference console URL https://console.cloud.google.com/compute/instances?project=noetl-demo-19700101.

## Actions
- Rolled out `ghcr.io/noetl/noetl:v2.10.10` using `repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml`.
- Verified `noetl-server` and `noetl-worker` images and pod readiness on `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- Ran `git submodule sync --recursive` and `git submodule update --init --recursive` from `ai-meta` root.
- Fast-forwarded `ai-meta` `main` with `git pull --ff-only`.
- Recorded project ownership context note for `noetl-demo-19700101` under Adiona.org.

## Repos
- `repos/ops`
- `repos/noetl`
- `ai-meta`

## Related
- GCP console reference: `https://console.cloud.google.com/compute/instances?project=noetl-demo-19700101`
