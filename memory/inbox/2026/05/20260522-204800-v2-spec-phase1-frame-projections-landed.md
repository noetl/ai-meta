# v2 distributed-runtime spec — Phase 1 (frame projections) landed
- Timestamp: 2026-05-22T20:48:00Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,projector,frames,phase1,distributed-runtime,release

## Summary

Phase 1 of the v2 distributed-runtime spec is complete. The projector
worker now writes per-frame projection records additively alongside
the existing per-execution records, closing the gap where frame state
existed in `noetl.frame` and `state["frames"]` (in the fold) but was
not directly queryable via `noetl.projection`.

NoETL released v2.90.0 carrying the change. PR #585 merged with
8 file changes (+535/-8), 39 tests green.

## What landed

- `ProjectionRecord` per frame keyed `frame/<frame_id>/<projection>` /
  `projection_type=replay_state:frame:<projection>` written after the
  per-execution record in the same `ReplayStateProjector.project()`
  call. No double folding — per-frame state slices come from
  `state["frames"][frame_id]` of the existing fold.
- Per-frame version + source_event_id computed against the per-frame
  **subset** of the input batch so monotonic upserts stay coherent
  when frames arrive out of order.
- New Prometheus counters:
  `noetl_projector_frame_projection_records_total` +
  `noetl_projector_frame_projection_stale_records_total`, plus
  matching `last_batch_*` gauges. Exposed in both Prometheus text
  exposition and the `/summary` JSON.
- Wiki page `noetl/projector.md` updated with the new "Frame
  projections" subsection and metrics-table entries — paired with
  the code change per the new `wiki-maintenance.md` rule.

## Pointers

- noetl: `8517fe7e -> 68eea845` (v2.90.0, including PR #585 merge `2a3e83bc`)
- noetl-wiki: `0769aca -> 03886a8`
- ai-meta: `593287e` (pointer bump) + `590e78a` (handoff archive)
- Handoff archive: `handoffs/archive/2026-05-22-phase1-frame-projections/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | **done (this round)** |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Arrow IPC Tier 1.5 | partial (cache + IpcHint exist; outbox/projector wiring open) |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter payload store | partial (event-store + projection-store ports exist; payload-store port missing) |
| 6 — stage planner for fanout/reduce | not started (planner exists at `build_fanout_reduce_plan`, not wired to engine) |

## Notes for next round

- **Phase 6** is the next-smallest delta — `build_fanout_reduce_plan`
  already exists and is documented at
  `noetl/core/dsl/engine/dsl_planner`. The work is wiring the
  planner output into the engine's stage opener so fan-outs mint
  frames at the planned boundaries. Estimated 2-3 days.
- Then **Phase 3** (Arrow IPC wiring at outbox/projector boundaries).
- Then **Phase 5** (payload store), then **Phase 4** (URN + KEDA +
  supercluster).

## Related

- agents/rules/wiki-maintenance.md — first usage validated: wiki page
  shipped alongside the code change in the same coordinated bump.
- agents/rules/handoffs.md — first usage with the dispatcher==executor
  pattern (same Claude session opened the handoff, executed phases
  A-D, gated F, then completed it post-merge). Result file at
  status=partial captures the gate-time snapshot; the merge follow-up
  lives in the chore(sync) commit message and this entry.
