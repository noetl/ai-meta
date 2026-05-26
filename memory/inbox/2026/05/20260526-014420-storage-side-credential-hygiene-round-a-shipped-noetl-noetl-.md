# Storage-side credential hygiene Round A shipped — noetl/noetl#604 merged, v2.100.7 cut
- Timestamp: 2026-05-26T01:44:20Z
- Author: Kadyapam
- Tags: noetl,security,storage,credentials,closed,pr604,v2.100.7

## Summary
PR #604 'fix(security): persist keychain refs for worker dispatch' merged on noetl/noetl. semantic-release published v2.100.7 (c26b0460). repos/noetl bumped f051d9c2 -> c26b0460. repos/noetl-wiki bumped 210b1c6 -> aad9b64 (page extension covering storage-side persistence + $noetl_ref shape + worker-side resolution). Implementation: new noetl/core/credential_refs.py helper (encode pure keychain expressions as $noetl_ref, defer mixed expressions, resolve at worker dispatch); keychain_processor + lifecycle no longer inject resolved values into ExecutionState.variables (workflow state gets _keychain_manifest with names only); commands.py encodes pure keychain templates as refs in command context and leaves mixed expressions as deferred templates; worker dispatch resolves refs/templates in-memory just before tool invocation; worker scrubs keychain namespace from result before persistence and event emission; one debug log that exposed resolved entry content fixed to log names only. Tests: 20 passed across 6 test files. Live GKE validation across 3 distributed executions on temp playbook tmp/storage-side-credential-hygiene-round-a: 0 cleartext keychain values in event/command/execution-state rows; 3 $noetl_ref command rows; 3 deferred-mixed-template command rows; 9 manifest event rows; 0 persisted keychain-namespace rows; 9 provider success rows confirming worker-side resolution still works. Out-of-scope (deferred to Round B): result store previews + extracted fields, transient.var_value, caller-provided result/temp API writes, Arrow IPC producer-side schema-aware policy. Read-side redaction from PR #603 retained as safety net. Thread 2026-05-24-noetl-storage-side-credential-hygiene archived (rounds 01/02 closed). Live cluster still on Helm rev 160 with storage-refs-round-a-20260526005308 image tag (same code as v2.100.7; will roll forward on next deploy).

## Actions
-

## Repos
-

## Related
-
