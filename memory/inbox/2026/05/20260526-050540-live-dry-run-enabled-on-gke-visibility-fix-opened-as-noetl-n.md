# Live dry-run enabled on GKE + visibility fix opened as noetl/noetl#609
- Timestamp: 2026-05-26T05:05:40Z
- Author: Kadyapam
- Tags: noetl,inline-execution,observability,bugfix,pr609

## Summary
Enabled NOETL_INLINE_TRIVIAL_CHILDREN=dry_run on the live GKE noetl-worker deployment after building inline-round-a-20260526042508 image and helm-upgrading to revision 162. Detector confirmed firing: ran synthetic itinerary-planner execution 635041599201739615 which completed in 12s (normal range; dispatch path unchanged). Worker INFO-level DEBUG-PAYLOAD logs show meta.inline_decision attached to the processed_response (one example: load_slot_state agent envelope had inline=false with reasons starting framework:ok:noetl). BUT discovered a Round A visibility gap: meta.inline_decision never reaches the event log. Root cause: Worker._extract_control_context in nats_worker.py:630 projects the agent envelope into result.context using a nested-scalars-only rule for dict-children. meta = {inline_decision: {dict}} is dict-of-dict so inline_decision was silently stripped. Fix shipped as draft PR noetl/noetl#609 (kadyapam/inline-decision-event-persistence branch, commit 6b0571aa): targeted carve-out mirroring error.diagnosis and render.args patterns. Adds 2 tests (15 pass total in test_control_context_projection.py). Wiki page updated with new Event-log persistence section under Logging, noetl-wiki commit dbf6c163 pushed but ai-meta pointer deferred until PR #609 merges (same deferral pattern as previous rounds). Live cluster still on inline-round-a image; after #609 merges and a new image deploys, decisions will land at result.context.meta.inline_decision queryable via /api/executions/{id}/events. Active thread 2026-05-26-noetl-inline-trivial-children remains active — Round B (actual inline execution path) still queued with wait phrase 'proceed with inline implementation' from round-01 prompt.

## Actions
-

## Repos
-

## Related
-
