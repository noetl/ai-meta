# Phase D v4 — Bug B fixed; vertex-ai-stub canned diagnosis flows; Bug C surfaced (cancel probe wrong endpoint)
- Timestamp: 2026-05-26T16:02:31Z
- Author: Kadyapam
- Tags: noetl,inline-execution,phase-d,bug-c,cancellation,pr-616

## Summary
Phase D re-run after PR #615 merged. Helm rev 169, image inline-runner-v4-20260526084305 (v2.102.3), NOETL_INLINE_TRIVIAL_CHILDREN=enforce. RESULT ENVELOPE FIXED: 5 vertex-ai-stub smoke turns all under 1s (warm 0.75s vs Round A 4s = 5x speedup). Parent's call.done result.context.data carries the full canned diagnosis (category, confidence, root_cause, vertex-stub, gemini-2.0-flash markers all present). Keychain redaction preserved through inline runner's ResultHandler scrub ([REDACTED] on token usage). Inline metadata correct (inline_mode=worker, inlined_in_parent), child id 18-digit. BUG C SURFACED during parent-cancel cascade spot-check (exec 635384123825062053 cancelled at t=1.5s): noetl cancel succeeded, execution.cancelled event landed, /api/executions/<id>/cancellation-check returns cancelled:true, BUT the inline runner ran all 3 child steps to completion (6s of sleeps after a 1.5s cancel). Root cause: _make_cancellation_probe hits /status (no status field) instead of /cancellation-check. The /status endpoint shape has completed/failed/current_step but no status field at top level; doc.get('status') returns None, probe always returns False. Round-01 design specified /cancellation-check as the seam — codex hit the wrong URL. PR #616 open with the fix + 7 regression tests. 63/63 tests pass. Worker reverted to dry_run on GKE.

## Actions
-

## Repos
-

## Related
-
