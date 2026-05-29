# Gateway #12 + ops #120 merged + deployed; SPA hang fix live on GKE
- Timestamp: 2026-05-27T05:21:15Z
- Author: Kadyapam
- Tags: gateway,ops,deployed,helm,nats,spa-hang,pr-12,pr-120

## Summary
Gateway PR #12 merged as 5dc2339 → v2.11.1 (8d75849). Ops PR #120 merged as eef0811. Built gateway image spa-fix-20260526215539 via Cloud Build (16m22s — Rust+alpine is slow). Helm rev 128 on noetl-gateway in gateway namespace. Gateway env NATS_UPDATES_SUBJECT_PREFIX now noetl.events. (was playbooks.executions.). Note: --reuse-values does NOT pick up new chart defaults, had to explicit --set env.natsUpdatesSubjectPrefix on the upgrade. User now retesting travel.mestumre.dev SPA flow. Cluster state otherwise unchanged: noetl helm rev 174, noetl image inline-runner-v8-20260526204911 (v2.102.7), worker on NOETL_INLINE_TRIVIAL_CHILDREN=off. Expected behavior: SPA's waitForExecutionCompletion now resolves because gateway receives playbook.completed NATS events under noetl.events.{tenant}.{org}.{exec_id}.{shard} subjects, parser correctly extracts exec_id from position 2, request_store routes SSE frame to the right client.

## Actions
-

## Repos
-

## Related
-
