# #90 Phase 6 shipped — CLI local noetl subscribe (cli v4.11.0)
- Timestamp: 2026-06-12T14:31:09Z
- Author: Kadyapam
- Tags: noetl,subscription,cli,phase-6,issue-90,local-mode,spool

## Summary
noetl subscribe runs a kind:Subscription listener standalone in local mode (no k8s/server for the listening): reuses noetl_tools source+spool engine + emits the same ExecutorEvent envelope to a local FileEventSink (JSONL); in-process PlaybookRunner dispatch (RFC §5.3) or POST /api/execute; local_disk spool. cli-only — NO tools change/crate cascade (source+spool already in noetl-tools v3.5.0; bumped the lock 3.0.0→3.5.0 via executor's '3'). Live local proof on in-cluster NATS (kind): 5/5 drained+dispatched+COMPLETED + 19-event trail; 6/6 buffered to local_disk under outage → replayed in order on recovery. Finding: NATS source ignores URL-embedded user:pass (async-nats ConnectOptions) — use explicit user/password. ai-meta→cli 2fb3fb0. #90 Phases 1-6 complete; stays OPEN for Phase 7 (scale hardening, volume-gated).

## Actions
-

## Repos
-

## Related
-
