# NoETL v2.10.3 local+gke deploy and amadeus token smoke validation
- Timestamp: 2026-03-06T19:44:32Z
- Author: Kadyapam
- Tags: deployment,validation,kind,gke,playbook,ops

## Summary
Deployed NoETL v2.10.3 to local kind (via repos/ops automation/development/noetl.yaml) and to GKE noetl-demo-19700101/us-central1/noetl-cluster (via automation/gcp_gke/noetl_gke_fresh_stack.yaml). Added playbook fixture tests/fixtures/playbooks/api_integration/amadeus_ai_token_smoke and validated execution in both environments with OpenAI and Amadeus checks returning HTTP 200. Verified gateway CORS preflight/login from https://mestumre.dev to https://gateway.mestumre.dev.

## Actions
- Added fixture playbook: `repos/noetl/tests/fixtures/playbooks/api_integration/amadeus_ai_token_smoke/amadeus_ai_token_smoke.yaml`.
- Committed and pushed to `repos/noetl` `master`: `582ca102` with message `fix: add amadeus ai token smoke fixture playbook`.
- Redeployed local kind stack using `repos/ops/automation/development/noetl.yaml` (`action=redeploy`).
- Executed `api_integration/amadeus_ai_token_smoke` on local runtime:
  - `execution_id=576792407379804361`
  - result: `completed=true`, `failed=false`, `openai_status=200`, `amadeus_status=200`
- Deployed GKE stack using `repos/ops/automation/gcp_gke/noetl_gke_fresh_stack.yaml` with:
  - `project_id=noetl-demo-19700101`, `region=us-central1`, `cluster_name=noetl-cluster`
  - `noetl_image_repository=ghcr.io/noetl/noetl`, `noetl_image_tag=v2.10.3`
- Executed `api_integration/amadeus_ai_token_smoke` on GKE runtime:
  - `execution_id=576791161948340334`
  - result: `completed=true`, `failed=false`, `openai_status=200`, `amadeus_status=200`
- Validated public endpoints:
  - `https://mestumre.dev` returns HTTP 200
  - CORS preflight for `POST /api/auth/login` on `https://gateway.mestumre.dev` allows `Origin: https://mestumre.dev`.

## Repos
- `repos/noetl`
- `repos/ops`
- `ai-meta`

## Related
- Release target: `ghcr.io/noetl/noetl:v2.10.3`
- Cluster context: `gke_noetl-demo-19700101_us-central1_noetl-cluster`
