# Handed travel Anthropic re-smoke to Codex — pending GCP secret provisioning
- Timestamp: 2026-05-09T19:42:30Z
- Author: unknown
- Tags: ai-os,travel-agent,multi-provider,anthropic,re-smoke,gcp-secret,bridge,codex,handoff,smoke-only

## Summary
Multi-provider round shipped the code GREEN. OpenAI baseline regression-clean. Anthropic fallback path proven (snaps to OpenAI with provider_fallback_reason audit field). True Anthropic GREEN blocked because GCP secret projects 1014428265962 secrets anthropic-api-key versions 1 returned NOT_FOUND and no local ANTHROPIC_API_KEY env was set on cluster. Kadyapam provisions the secret out-of-band via gcloud secrets create or versions add with the actual API key from anthropic console. Bridge task bridge/inbox/delegated/20260509-194100-travel-anthropic-resmoke.task.json hands smoke-only re-run to Codex 4 phases verify secret accessible matches workload version path; smoke help flights locations with --provider anthropic confirming effective_provider equals anthropic and provider_fallback_reason absent; OpenAI regression check; close out result file plus optional validation log append on GREEN. Cap 0 PRs (smoke only) but Codex may need 1 ops PR if workload version-path field needs to bump to match where secret actually got created. Codex prompt at scripts/travel_anthropic_resmoke_msg.txt. Architectural rules Codex does not provision secret itself only verifies read-only via gcloud secrets versions access never echo full secret value into result file or screenshots. No ai-meta push.

## Actions
-

## Repos
-

## Related
-
