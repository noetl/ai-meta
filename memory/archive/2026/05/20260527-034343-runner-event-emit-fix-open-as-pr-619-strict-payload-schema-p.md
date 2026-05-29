# Runner event-emit fix open as PR #619 — strict payload schema + parent catalog_id wiring + silent-drop guard
- Timestamp: 2026-05-27T03:43:43Z
- Author: Kadyapam
- Tags: noetl,inline-execution,runner-defect,pr-619,catalog_id,payload-schema,silent-drop-guard

## Summary
PR #619 (branch kadyapam/inline-runner-event-emit-schema-and-catalog-id, commit efd4953b) addresses the three Round B runner defects that hung the itinerary-planner flow: (1) _emit_init_events placed workload/playbook_path in payload.result — moved to payload.meta. (2) _emit_workflow_completed spread tool result dict into payload.result — wrapped in payload.result.context. (3) parent catalog_id was never propagated — added BatchEventRequest.catalog_id optional field; server _persist_batch_acceptance uses it as fallback when DB lookup returns None; new _BatchEventEmitter class with set_catalog_id mutator; execute_agent_task extracts context.catalog_id and wires it through. Bonus: persistent emission failures now upgrade to WARNING at consecutive_failures >= 3 — the Phase D silent-drop lesson encoded. 130 tests pass (8 new). Cluster currently on NOETL_INLINE_TRIVIAL_CHILDREN=off via kubectl set env (emergency revert kept). After merge: bump pointer, rebuild image, redeploy GKE, re-flip enforce, re-run itinerary-planner end-to-end, watch server logs for /api/events/batch 500s.

## Actions
-

## Repos
-

## Related
-
