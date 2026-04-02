# NoETL v2.10.15 deployed to GKE via ops playbook
- Timestamp: 2026-03-19T18:28:33Z
- Author: Kadyapam
- Tags: gke,deploy,release,v2.10.15,ops-playbook,ai-meta,submodules

## Summary
Refreshed ai-meta and submodules from repository root using git pull --ff-only, git submodule sync --recursive, and git submodule update --init --recursive. Deployed NoETL release v2.10.15 to gke_noetl-demo-19700101_us-central1_noetl-cluster using repos/ops automation/gcp_gke/noetl_gke_fresh_stack.yaml with action=deploy and noetl_image_repository=ghcr.io/noetl/noetl, noetl_image_tag=v2.10.15. Verified deployments and pods are running ghcr.io/noetl/noetl:v2.10.15 and /health returned HTTP 200.

## Actions
- Pulled latest `ai-meta` on `main` with `git pull --ff-only`.
- Refreshed submodules with `git submodule sync --recursive` and `git submodule update --init --recursive`.
- Ran `gcloud container clusters get-credentials noetl-cluster --region us-central1 --project noetl-demo-19700101`.
- Deployed with `repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml` (`action=deploy`, `noetl_image_tag=v2.10.15`).
- Verified `noetl-server` and `noetl-worker` images/pods and checked `/health` endpoint.

## Repos
- `ai-meta`
- `repos/ops`

## Related
- Release: `https://github.com/noetl/noetl/releases/tag/v2.10.15`
