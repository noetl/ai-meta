# Kind redeploy finalization after context correction
- Timestamp: 2026-03-06T19:50:54Z
- Author: Kadyapam
- Tags: kind,deployment,validation,rollout

## Summary
Completed a second local kind redeploy after correcting kubectl context from GKE back to kind-noetl, forced old server pod termination to allow single-server handover, and re-ran amadeus token smoke execution successfully on local image local/noetl:2026-03-06-11-45.

## Actions
- Corrected kubectl context from GKE to kind:
  - `kubectl config use-context kind-noetl`
- Re-ran local deploy workflow:
  - `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`
- Observed rolling-update contention where new server pod initially failed readiness while old server pod remained active.
- Forced old server pod termination to complete handover to the new replica.
- Verified final kind runtime image:
  - `noetl-server` and `noetl-worker` => `local/noetl:2026-03-06-11-45`
- Re-executed `api_integration/amadeus_ai_token_smoke` against local API:
  - `execution_id=576795935536054729`
  - result: `completed=true`, `failed=false`, `openai_status=200`, `amadeus_status=200`

## Repos
- `repos/ops`
- `repos/noetl`
- `ai-meta`

## Related
- Primary GKE validation execution: `576791161948340334`
