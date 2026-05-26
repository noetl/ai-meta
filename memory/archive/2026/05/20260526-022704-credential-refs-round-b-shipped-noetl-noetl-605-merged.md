# Credential refs Round B shipped — noetl/noetl#605 merged
- Timestamp: 2026-05-26T02:27:04Z
- Author: Kadyapam
- Tags: noetl,security,producer-scrub,closed,pr605,credential-refs-arc-complete

## Summary
PR #605 'fix(security): scrub producer-side credential payloads' merged on noetl/noetl. repos/noetl bumped c26b0460 -> db6fbcf3 (merge commit; semantic-release tag will follow). repos/noetl-wiki bumped aad9b64 -> d54f04c (page extension covering producer-side scrub + Arrow IPC strategy + API endpoint defense-in-depth). Implementation: extended noetl/core/credential_refs.py with producer_scrub_payload composing with PR #603/#604 helpers; patched 5+1 surfaces (worker result_handler before preview/extracted-fields; worker transient before var_value persist; POST /api/result and POST /api/temp endpoints at write boundary as defense-in-depth; noetl/core/storage/result_store.py producer-side Arrow scrub before serialization; direct default_store.put callers consolidated into the same store boundary instead of as a sixth surface). Arrow IPC strategy: decode valid stream bytes, scrub row values, reserialize; invalid bytes left unchanged for backward compat. Tests: 31 passed in focused regression suite (includes Round A tests confirming no regression). Live GKE validation (Helm rev 161, image credential-refs-round-b-20260526020112) execution 634970636074353484 exercised all 6 paths: 0 placeholder/bearer hits across event/transient/state; 1 [REDACTED] in transient + state proving scrub fired; /api/api/result and /api/api/temp resolve checks returned HTTP 200 with 0 placeholder hits, 3 redacted hits each; Arrow + direct-store + result-handler authorization values all redacted; playbook still completed successfully. Read-side redaction PR #603 + Round A storage-side PR #604 unchanged — three-layer defense in place. Round B thread archived. Three observations codex flagged (none blocking): full pytest collection still has unrelated pre-existing module-missing failures; live deployed routes resolve as /api/api/result/... due to app-level prefix stacking with router prefix (pre-existing); NATS KV readback timeout on early validation, switched to memory-tier writes. Credential hygiene arc now complete across read-side (output), storage-side structured fields (Round A), and producer-side derived/transient/Arrow surfaces (Round B).

## Actions
-

## Repos
-

## Related
-
