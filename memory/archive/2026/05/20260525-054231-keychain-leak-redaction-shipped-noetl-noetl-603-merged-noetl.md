# Keychain leak redaction shipped — noetl/noetl#603 merged, noetl bumped to fb38b07f
- Timestamp: 2026-05-25T05:42:31Z
- Author: Kadyapam
- Tags: noetl,security,redaction,closed,pr603,v2.100.6-pending

## Summary
PR noetl/noetl#603 'fix(security): redact resolved keychain values from HTTP responses' merged. repos/noetl bumped 69d55d40 -> fb38b07f. New redact_keychain_values() helper in noetl/core/sanitize.py paralleling redact_url_credentials from #601; detection by both key pattern (token/secret/api_key/password/authorization/keychain/credential/private-key) and value pattern (bearer/basic/JWT-shaped/provider-key-prefix/private-key-headers/credential-bearing-query-params); idempotent; placeholder [REDACTED]. Redaction wired into 11 serialization seams in noetl-server (executions {status, detail, events}, vars list+single, result+temp resolve+get, context render, aggregate, replay, broker event reads, command debug, batch status, analyze flows). Worker dispatch path intentionally unchanged. Live GKE verification: same execution went from 73 secret-bearing response paths before to 0 after. 15 focused redaction tests pass. 126 API tests pass; 3 unrelated pre-existing failures. agents/rules/execution-model.md gained a 5-line cross-link to the new noetl-wiki page. repos/noetl-wiki bumped to 210b1c69 with new secrets-and-redaction.md page. Live cluster currently runs Helm rev 158 with temp tag keychain-redaction-69d55d40-20260524125244 (same code as the merged PR, will roll forward on next official release tag). Thread 2026-05-24-noetl-keychain-leak-redaction archived. Follow-up handoff already open: 2026-05-24-noetl-storage-side-credential-hygiene (close the storage boundary, persist references not cleartext, event log immutability respected).

## Actions
-

## Repos
-

## Related
-
