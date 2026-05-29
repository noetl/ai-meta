# Hotfix continuation #618 merged + deployed on GKE; wiki updated with two-tier redaction rule
- Timestamp: 2026-05-27T01:46:46Z
- Author: Kadyapam
- Tags: noetl,security,hotfix,pr-617,pr-618,wiki,deployed,sanitize,credential-alias

## Summary
PR #618 merged as 7aaa57ee; release v2.102.6 published (dc90d10a). Built inline-runner-v7-20260526182431, helm upgrade noetl on noetl-demo-19700101 to rev 173 (server+worker on v7). In-cluster verification: redact_keychain_values({auth:pg_auth}) returns alias preserved, redact_keychain_values({auth:'Bearer ...'}) still redacts. Both _sanitize_recursive AND _redact_response_recursive now use the two-tier match: caller-supplied additional_keys (HEADER_CREDENTIAL_KEYS, keychain manifest) blind redact; partial-match-only does combined key+value check. Wiki repos/noetl-wiki/noetl/core/secrets-and-redaction.md updated (commit ac520d6) with: 'What the helper catches' section now describes the two-tier rule + new 'Credential alias passthrough' subsection explaining why the partial-match tier preserves aliases; historical note linking PR #617/#618 and the production failure on noetl-demo. Auth login flow (https://travel.mestumre.dev/callback) now expected to succeed: worker fetches /api/temp/.../render_context → db_credential:pg_auth preserved → Jinja renders {{ db_credential }} to pg_auth → worker fetches /api/credentials/pg_auth → resolved DSN → postgres create_user_session succeeds → gateway returns 200.

## Actions
-

## Repos
-

## Related
-
