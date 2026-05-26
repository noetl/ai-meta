# Production hotfix PR #617 — sanitize_sensitive_data was destroying credential aliases on cluster
- Timestamp: 2026-05-26T20:34:26Z
- Author: Kadyapam
- Tags: noetl,security,production-hotfix,pr-617,sanitize,credential-alias

## Summary
User reported https://travel.mestumre.dev/callback returning 'Gateway login failed (401): Failed to create session: Database error' after my chart rollout. Root cause is a latent bug in noetl.core.sanitize._sanitize_recursive that has been live since PR #603 (b6839f25 redact resolved keychain values), not from today's Round B work or the chart change. Server log showed worker fetching /api/credentials/%5BREDACTED%5D?include_data=true — the literal [REDACTED] was the alias. The auth0_login_optimized playbook has workload.db_credential: pg_auth and step auth: {{ db_credential }}. The sanitizer's partial-substring key match (db_credential contains credential, auth exact-matches auth) blindly redacted the alias VALUES, not just real secret values. Worker's lookup of /api/credentials/[REDACTED] 404'd, postgres step ran with no DSN, create_user_session returned zero rows, playbook routed to send_db_error_callback, gateway returned 401. Hotfix at PR #617 (branch kadyapam/claim-endpoint-no-redact-worker-only, commit b050cd97) in repos/noetl. Changes _sanitize_recursive to combine key+value checks: short identifier strings under sensitive keys pass through (aliases preserved); Bearer/JWT/AWS/PEM/long-random patterns still redact; nested dicts/lists still blanket-redact. New tests/core/test_sanitize_sensitive_data.py with 17 cases. 49/49 sanitize-related tests pass. After merge: rebuild image (v2.102.5), redeploy GKE, retry login. Cluster is currently on inline-runner-v5-20260526090617 (helm rev 171, enforce). NOT related to Round B / Phase D — pre-existing redaction bug, just first time tested in the auth login flow.

## Actions
-

## Repos
-

## Related
-
