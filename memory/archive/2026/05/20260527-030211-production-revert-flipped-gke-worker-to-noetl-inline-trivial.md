# Production revert — flipped GKE worker to NOETL_INLINE_TRIVIAL_CHILDREN=off; itinerary-planner-class runner defects
- Timestamp: 2026-05-27T03:02:11Z
- Author: Kadyapam
- Tags: noetl,inline-execution,production-revert,runner-defect,catalog_id,payload-schema

## Summary
After successful login (PR #618 hotfix landed), user reported itinerary-planner playbook hanging on 'Muno is planning...'. Server log showed three runner-side defects against the inline event-emit path: (1) ValueError: payload.result includes unsupported keys: playbook_path, workload — runner's _emit_init_events builds payload shape the server's _validate_reference_only_payload rejects. (2) psycopg.errors.NotNullViolation: null value in column catalog_id of relation event_2027_h1 — runner doesn't include catalog_id when emitting child step events (firestore_dispatch, end). (3) Similar payload.result keys: data, id. Failed pattern: command.started + call.done events for firestore_dispatch step (kind:python in firestore mcp playbook). Phase D vertex-ai-stub smoke didn't trigger these because the catalog_id/payload schema may differ in itinerary-planner's deeper agent chain. Round B runner is NOT production-ready for the itinerary-planner shape. Immediate action: kubectl set env deployment/noetl-worker NOETL_INLINE_TRIVIAL_CHILDREN=off on GKE — direct env beats ConfigMap envFrom. All 3 worker pods now run with off. Inline runner disabled. Dispatched path serves all kind:agent calls. Travel SPA itinerary-planner should work again. Cluster: helm rev 173, image inline-runner-v7-20260526182431 (v2.102.6 with #617+#618 sanitize fixes intact, just inline mode disabled). NEXT: open noetl PR to fix runner event-emit to include catalog_id and use the schema-validated reference-only payload shape; add itinerary-planner-class regression smoke before re-enabling enforce.

## Actions
-

## Repos
-

## Related
-
