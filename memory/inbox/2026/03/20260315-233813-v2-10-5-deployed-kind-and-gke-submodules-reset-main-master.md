# v2-10-5-deployed-kind-and-gke-submodules-reset-main-master
- Timestamp: 2026-03-15T23:38:13Z
- Author: Kadyapam
- Tags: noetl,release,v2.10.5,deploy,kind,gke,submodules,ai-meta

## Summary
After merges (`noetl#260`, `ops#2`, `docs#5`), moved submodules back to default branches (`noetl: master`, `docs: main`, `ops: main`), repinned ai-meta submodule SHAs to merged heads, and deployed new NoETL release `v2.10.5` to local kind and GKE cluster `gke_noetl-demo-19700101_us-central1_noetl-cluster`.

## Actions
- Confirmed release publication:
  - `https://github.com/noetl/noetl/releases/tag/v2.10.5`
  - published at `2026-03-15T23:09:37Z`.
- Local kind redeploy from latest `repos/noetl` (`master`):
  - `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`
  - image built/deployed: `local/noetl:2026-03-15-16-12`.
  - final state:
    - `noetl-server` image `local/noetl:2026-03-15-16-12`, ready `1/1`
    - `noetl-worker` image `local/noetl:2026-03-15-16-12`, ready `3/3`.
- GKE deploy to current runtime cluster:
  - `noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml --runtime local --set action=deploy --set project_id=noetl-demo-19700101 --set region=us-central1 --set cluster_name=noetl-cluster --set build_images=false --set noetl_image_repository=ghcr.io/noetl/noetl --set noetl_image_tag=v2.10.5`
  - Deploy step succeeded for NoETL rollout; playbook ended non-zero only at final auth bootstrap wait (`provision_auth_schema` timeout).
  - cluster verification after run:
    - `noetl-server` image `ghcr.io/noetl/noetl:v2.10.5`, ready `1/1`
    - `noetl-worker` image `ghcr.io/noetl/noetl:v2.10.5`, ready `2/2`.
- Status check run:
  - `noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml --runtime local --set action=status --set project_id=noetl-demo-19700101 --set region=us-central1 --set cluster_name=noetl-cluster`

## Submodule Heads
- `repos/noetl` -> `7e0ea9a1` (`master`)
- `repos/docs` -> `d8acf7bd` (`main`)
- `repos/ops` -> `1803ad67` (`main`)

## Notes
- No mandatory memory-stack compaction/archive command is required for deploy operations; append-only inbox updates are sufficient for this workflow.
