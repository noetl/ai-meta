# noetl#602 merged — catalog scope semantic fix shipped in v2.100.5
- Timestamp: 2026-05-24T01:27:47Z
- Author: Kadyapam
- Tags: noetl,catalog,scope-normalization,bugfix,pr602,v2.100.5,housekeeping

## Summary
PR #602 merged at 6f26bce7 + v2.100.5 release commit 69d55d40. CatalogService._extract_agent_metadata gains two fixes: (1) distinguishes terminal['scopes']=[] (explicit empty) from missing — the short-circuit-or collapse bug is fixed; (2) filters None entries from the scope list before stringifying so stray Nones don't leak through as the literal string 'None'. Singular terminal['scope'] form still supported for back-compat. 12 tests pass. Pointer: noetl a17bb8cb → 69d55d40. This was the older Codex stash (kadyapam/catalog-agent-discovery-kind) picked up during housekeeping after #600/#601 closed out. Both noetl stashes now drained. Deploy bundle now contains three sequential fixes for the next GKE image rebuild: #600 consumer drift self-heal (v2.100.3), #601 NATS URL credential redaction (v2.100.4), #602 catalog scope semantic fix (v2.100.5). One image build picks up all three.

## Actions
-

## Repos
-

## Related
-
