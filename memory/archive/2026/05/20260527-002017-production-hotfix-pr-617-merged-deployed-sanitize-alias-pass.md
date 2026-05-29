# Production hotfix PR #617 merged + deployed — sanitize alias passthrough live on GKE
- Timestamp: 2026-05-27T00:20:17Z
- Author: Kadyapam
- Tags: noetl,security,hotfix,pr-617,gke,deployed,sanitize,credential-alias

## Summary
PR #617 merged as 91e8e308; release v2.102.5 published (992149b1). ai-meta pointer bumped. Built inline-runner-v6-20260526150402 image from v2.102.5, helm upgrade noetl on noetl-demo-19700101 GKE cluster to rev 172 (server + worker both on v6). In-cluster verification: sanitize_sensitive_data({'auth':'pg_auth','db_credential':'pg_auth'}) returns aliases preserved; sanitize_sensitive_data({'auth':'Bearer eyJhbGciOi...'}) still redacts. Inline-execution smoke (exec 635638220306252187) completed 1.117s with the v6 image — Round B still works post-hotfix. Final cluster state: server+worker on inline-runner-v6, NOETL_INLINE_TRIVIAL_CHILDREN=enforce sourced via configMapRef (direct env override empty, chart-backed). User can retry https://travel.mestumre.dev/callback login — should now succeed because credential alias pg_auth no longer mangled to [REDACTED].

## Actions
-

## Repos
-

## Related
-
