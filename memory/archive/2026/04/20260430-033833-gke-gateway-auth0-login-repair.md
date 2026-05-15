# GKE Gateway Auth0 login repair
- Timestamp: 2026-04-30T03:38:33Z
- Author: Codex
- Tags: gke,gateway,auth0,e2e,docs,noetl

## Summary
Fixed the GKE Gateway Auth0 login failure without storing secrets. Root cause: the registered api_integration/auth0/auth0_login system playbook still addressed prepared Python output through older result paths, while the current distributed NoETL runtime exposes compacted Python output through prepare_session_cache.context.* for later steps. The stale playbook produced successful callbacks with null user fields, which Gateway rejected as Invalid email/failed login. repos/e2e commit 031ec71 updates the playbook to read current task-sequence row shapes and callback/cache from prepare_session_cache.context.*; the playbook was re-registered in GKE as version 76 and a synthetic token smoke returned HTTP 200 with populated user metadata. repos/docs commit 25bd7c5 adds GKE/Gateway/Auth0 deployment and troubleshooting instructions, including how to re-register auth playbooks from repos/e2e and avoid real passwords in terminal tests.

## Actions
-

## Repos
-

## Related
-
