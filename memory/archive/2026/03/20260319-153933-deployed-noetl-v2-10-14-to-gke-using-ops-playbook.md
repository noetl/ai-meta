# deployed-noetl-v2-10-14-to-gke-using-ops-playbook
- Timestamp: 2026-03-19T15:39:33Z
- Author: Kadyapam
- Tags: gke,deploy,ops,noetl,release,v2.10.14,noetl-cluster

## Summary
Ran gcloud get-credentials for noetl-cluster in noetl-demo-19700101 and deployed via ops playbook automation/gcp_gke/noetl_gke_fresh_stack.yaml with action=deploy, build_images=false, noetl_image_repository=ghcr.io/noetl/noetl, noetl_image_tag=v2.10.14. Rollout completed for noetl-server and noetl-worker; deployment images on cluster are ghcr.io/noetl/noetl:v2.10.14.

## Actions
- `gcloud container clusters get-credentials noetl-cluster --region us-central1 --project noetl-demo-19700101`
- `noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml --runtime local --set action=deploy --set project_id=noetl-demo-19700101 --set region=us-central1 --set cluster_name=noetl-cluster --set build_images=false --set noetl_image_repository=ghcr.io/noetl/noetl --set noetl_image_tag=v2.10.14`
- `kubectl --context gke_noetl-demo-19700101_us-central1_noetl-cluster -n noetl get deploy noetl-server noetl-worker -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'`

## Repos
- `repos/ops`
- `repos/noetl`
- `repos/ai-meta`

## Related
- GKE cluster: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
- Playbook: `repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml`
