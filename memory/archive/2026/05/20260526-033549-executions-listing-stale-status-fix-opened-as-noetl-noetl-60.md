# Executions-listing stale-status fix opened as noetl/noetl#606; noetl bumped to v2.100.8
- Timestamp: 2026-05-26T03:35:49Z
- Author: Kadyapam
- Tags: noetl,api,listings,bugfix,pr606,v2.100.8

## Summary
Drove the executions-listing-stale-status follow-up directly (no codex handoff per user direction). The /api/executions listings endpoint was relying solely on noetl.execution projection columns (status, last_event_type, end_time), which can lag the immutable event log when playbook.completed / playbook.failed / workflow.completed / workflow.failed / execution.cancelled fires but the projection write is delayed or missed. Per-execution /api/executions/{id}/status was always correct because it reads the event log directly. Listings reported stale RUNNING for 82/100 rows during the 2026-05-24 production triage. Fix: LEFT JOIN LATERAL against noetl.event for each row in the page to find the latest terminal event; prefer event-log-derived event_type/status/created_at over projection columns; in-progress executions still read projection as fallback. The existing index idx_event_exec_type ON noetl.event (execution_id, event_type, event_id DESC) makes the per-row lookup O(log n), so the endpoint stays inside the 8s statement_timeout. Tests: new regression test_get_executions_uses_event_log_lateral_for_terminal_state covering the stale-projection scenario; updated test_get_executions_applies_page_size_and_offset to assert LATERAL is now present; all 15 tests pass. Wiki updated: noetl-wiki/noetl/server/api/execution.md 'List' section gained a 'Terminal-state derivation' paragraph documenting the LATERAL join. PR: https://github.com/noetl/noetl/pull/606 (draft, not merged). Wiki commit 3900e2c pushed to master. Opportunistic catch-up: repos/noetl pointer bumped db6fbcf3 -> efed4dff (the v2.100.8 release tag that semantic-release published after PR #605 merged). repos/noetl-wiki pointer NOT bumped to 3900e2c yet — defer until PR #606 merges so ai-meta doesn't point at wiki content describing unmerged code. Followed the same convention as previous rounds. Two queued items remain: noetl-platform-step-overhead-reduction (the actual <2s latency work), and Round B archive cleanup (now done). No active handoff thread for the listings fix; documented via PR + memory + wiki edit.

## Actions
-

## Repos
-

## Related
-
