# ops gke deploy defaults to published v2.8.9
- Timestamp: 2026-03-04T03:29:07Z
- Tags: ops,gke,deploy,images,noetl-v2.8.9

## Summary
Updated ops GKE playbook defaults to deploy published NoETL image ghcr.io/noetl/noetl:v2.8.9 with build_images disabled by default, and validated behavior via action=status run.

## Actions
- Updated `ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml` defaults:
  - `build_images=false`
  - `build_noetl_image=false`
  - `build_gateway_image=false`
  - `build_gui_image=false`
  - `noetl_image_repository=ghcr.io/noetl/noetl`
  - `noetl_image_tag=v2.8.9`
- Updated docs/examples in:
  - `ops/automation/gcp_gke/README.md`
  - `ops/README.md`
- Verified published image availability:
  - `docker manifest inspect ghcr.io/noetl/noetl:v2.8.9` -> exists.
- Ran validation command:
  - `noetl run automation/gcp_gke/noetl_gke_fresh_stack.yaml --runtime local --set action=status --set project_id=noetl-demo-19700101 --set region=us-central1 --set cluster_name=noetl-cluster`
  - Result: playbook executed deploy-related steps and failed waiting rollout (`timed out waiting for the condition`), indicating `action=status` routing still traverses deployment path.

## Repos
- noetl/ops: `main` -> `68d80b2`
- noetl/ai-meta: submodule pointer bump pending commit
