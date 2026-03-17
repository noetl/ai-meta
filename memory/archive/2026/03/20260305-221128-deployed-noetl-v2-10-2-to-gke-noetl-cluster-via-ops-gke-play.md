# Deployed NoETL v2.10.2 to GKE noetl-cluster via ops gke playbook
- Timestamp: 2026-03-05T22:11:28Z
- Author: Kadyapam
- Tags: gke,deploy,ops,release,v2.10.2,noetl-cluster

## Summary
Updated repos/noetl submodule to release commit b77df312 (v2.10.2) and deployed to GKE using repos/ops automation/gcp_gke/noetl_gke_fresh_stack.yaml in local runtime mode with action=deploy, project_id=noetl-demo-19700101, region=us-central1, cluster_name=noetl-cluster, noetl_image_repository=ghcr.io/noetl/noetl, noetl_image_tag=v2.10.2. Verified cluster context gke_noetl-demo-19700101_us-central1_noetl-cluster with noetl-server 1/1 and noetl-worker 2/2 on ghcr.io/noetl/noetl:v2.10.2.

## Actions
- Switched `repos/noetl` to release tag `v2.10.2` (`b77df312`) before deployment.
- Ran GKE deployment playbook from `repos/ops`:
  `noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml --runtime local --set action=deploy --set project_id=noetl-demo-19700101 --set region=us-central1 --set cluster_name=noetl-cluster --set build_images=false --set noetl_image_repository=ghcr.io/noetl/noetl --set noetl_image_tag=v2.10.2`
- Verified rollout in GKE context `gke_noetl-demo-19700101_us-central1_noetl-cluster`.
- Confirmed deployed images for `noetl-server` and `noetl-worker` are `ghcr.io/noetl/noetl:v2.10.2`.

## Repos
- `noetl/ai-meta`: submodule pointer bump to `repos/noetl` commit `b77df312`
- `noetl/noetl`: release `v2.10.2`

## Related
- Release: `https://github.com/noetl/noetl/releases/tag/v2.10.2`
- GKE cluster: `https://console.cloud.google.com/kubernetes/clusters/details/us-central1/noetl-cluster/overview?project=noetl-demo-19700101`
