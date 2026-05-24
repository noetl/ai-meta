# noetl#601 merged — NATS URL credential redaction shipped in v2.100.4
- Timestamp: 2026-05-24T00:23:23Z
- Author: Kadyapam
- Tags: noetl,logging,credential-redaction,security,bugfix,pr601,v2.100.4

## Summary
PR #601 merged at a9f3c8d4 + v2.100.4 release commit a17bb8cb. redact_url_credentials() helper in noetl/core/sanitize.py wires into five log sites (nats_client / nats_session_store / server core / worker startup × 2 + /tmp/worker_config.txt). Closes the credential leak codex flagged in the GKE worker diagnostic round — connection strings continue to be built and consumed verbatim; only their representation in logs and the worker debug dump is redacted. 29 tests pass: 15 new redaction tests + 14 NATS subscriber tests still green from #600. Pointer: noetl 25e62eb5 → a17bb8cb. Combined with PR #600 (consumer drift self-heal), the GKE worker image now needs ONE rebuild + push to Artifact Registry to pick up both fixes at once. Until then GKE workers retain the May-20 e3db3624 image and keep emitting credentialed NATS URLs to VictoriaLogs. Side note: still-stashed older work in repos/noetl stash@{0} (catalog scope-normalization improvement) — small refactor that distinguishes terminal['scopes']=[] from missing + filters None scope entries; not blocking anything.

## Actions
-

## Repos
-

## Related
-
