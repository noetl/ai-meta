# SPA hang diagnosed + fix PRs open: noetl/gateway #12 + noetl/ops #120
- Timestamp: 2026-05-27T04:49:30Z
- Author: Kadyapam
- Tags: gateway,nats,spa-hang,pr-12,pr-120,fix,not-round-b

## Summary
Codex's round-01 diagnosis pinned the SPA hang on a NATS subject mismatch — gateway subscribed to 'playbooks.executions.>' but noetl publishes on 'noetl.events.{tenant}.{org}.{exec_id}.{shard}' (nats_client.py::subject_for_event). Gateway received zero playbook.completed events; SPA waited forever for playbook/state SSE frame. NOT a Round B issue. NOT a sanitize/credential issue. Pre-existing config mismatch. Opened two PRs: noetl/gateway #12 fixes execution_id_from_subject in playbook_state.rs to skip tenant+org tokens (6/6 cargo tests pass); noetl/ops #120 flips NATS_UPDATES_SUBJECT_PREFIX from 'playbooks.executions.' to 'noetl.events.' in both Helm values and static manifest. Both PRs cross-reference each other; gateway PR ships first, then ops. After merge: bump pointers, helm upgrade gateway. Cluster currently helm rev 174, image inline-runner-v8-20260526204911 (v2.102.7), worker on NOETL_INLINE_TRIVIAL_CHILDREN=off. Once SPA fix lands, the wait phrase 'proceed with enforce re-test' unlocks the Round B re-test.

## Actions
-

## Repos
-

## Related
-
