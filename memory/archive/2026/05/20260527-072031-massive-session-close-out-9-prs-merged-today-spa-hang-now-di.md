# Massive session close-out: 9 PRs merged today; SPA hang now diagnosed to outbox arrow-feather vs gateway JSON; round-02 handoff prompt ready
- Timestamp: 2026-05-27T07:20:31Z
- Author: Kadyapam
- Tags: session-closeout,spa-hang,outbox,arrow-feather,nats,gateway,pr-12,pr-120,pr-121,db-schema

## Summary
Marathon session. Today's noetl/gateway/ops PRs merged + deployed: noetl #608-611, #612-619 (Round B inline-execution arc + sanitize fixes + runner event-emit + cancellation probe + ...), gateway #12 (NATS subject parser shape), ops #119 (NOETL_INLINE_TRIVIAL_CHILDREN chart-backed), #120 (NATS_UPDATES_SUBJECT_PREFIX → noetl.events.). Cluster state: helm rev 174 + image inline-runner-v8-20260526204911 (v2.102.7) on noetl, helm rev 128 + image spa-fix-20260526215539 on gateway, NOETL_EVENT_MIRROR_ENABLED=true via kubectl set env on noetl-server + noetl-worker, NOETL_INLINE_TRIVIAL_CHILDREN=off on worker. Login WORKS. SPA STILL HANGS at 'Muno is planning...'. NEW root cause: noetl outbox publishes arrow-feather binary on NATS (payload_bytes column in noetl.outbox table); gateway expects JSON. 438 outbox PUBLISHED rows but 438 gateway 'Failed to parse lifecycle NATS payload as JSON' warnings, zero successful playbook/state messages. Also discovered: cluster's DB schema is stale (noetl.outbox table was missing before today's session — I applied ensure_outbox_schema() in-cluster); full schema bump blocked by application user lacking ALTER ownership on pre-existing tables (transient et al), needs postgres admin DSN. Open ops PR #121 (chart-backed NOETL_EVENT_MIRROR_ENABLED=true) is BLOCKED — enabling without outbox table breaks /api/execute with NotNullViolation. Round-02 handoff prompt written + ready to commit, dispatches codex on a focused noetl PR (publish_outbox_batch JSON instead of arrow-feather).

## Actions
-

## Repos
-

## Related
-
