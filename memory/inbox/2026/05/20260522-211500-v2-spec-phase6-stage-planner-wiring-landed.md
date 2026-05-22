# v2 distributed-runtime spec — Phase 6 (stage-planner wiring) landed
- Timestamp: 2026-05-22T21:15:00Z
- Author: Kadyapam (via Claude session)
- Tags: noetl,v2-spec,planner,engine,phase6,distributed-runtime,release

## Summary

Phase 6 of the v2 distributed-runtime spec is complete. The fan-out/
reduce planner (`build_fanout_reduce_plan`) was already wired into
the engine for fan-out commands as of v2.90.0; this round closes
three remaining gaps without changing runtime behavior.

NoETL released v2.91.0 carrying the change. PR #586 merged with
5 file changes (+333 / -4), 122 tests green (6 new + Phase 1 regression
guard).

## What landed

1. **Plan caching.** `ExecutionState.fanout_reduce_plan` is a lazy
   `@property` that calls `build_fanout_reduce_plan(self.playbook)`
   once and memoizes. `transitions.py` now reads through the cached
   accessor instead of re-running the planner on every fan-out
   transition.

2. **Reducer-bound command annotation.** New
   `_annotate_reducer_commands` method runs after every transition.
   For any issued command whose `target_step` is a planned reducer,
   attaches `metadata["planner_reducer"]` with `planner_version`,
   `reducer_step`, `upstream_steps`, `source_step`. Static plan
   information; does not change runtime control flow.

3. **Register-time validation.**
   `validate_fanout_reduce_plan(playbook) -> list[str]` advisory
   linter in `planner.py`. Called from `DSLParser.parse` after
   Pydantic construction. Emits warning codes
   `[fanout_no_reducer]` (inclusive fan-out with no reachable
   reducer) and `[reducer_orphan]` (reducer with <2 upstream)
   via the `noetl.core.dsl.engine.planner` logger at WARNING
   level. Never raises.

## What's intentionally NOT in this round

**Reducer-wait semantics** — defer scheduling a reducer step until
all upstream commands terminate. Behavior change with replay
implications; deserves its own future round.

## Pointers

- noetl: `68eea845 -> c7f3cbd5` (v2.91.0, including PR #586 merge `7558d5e1`)
- noetl-wiki: `03886a8 -> 1fdb8c6`
- ai-meta: `441f4cf` (pointer bump) + `3fa0da5` (handoff archive)
- Handoff archive: `handoffs/archive/2026-05-22-phase6-stage-planner-wiring/`

## v2 spec status now

| Phase | Status |
|---|---|
| 0 — instrumentation + stage/frame tables + replay API | done |
| 1 — frame-shaped cursor loops | done |
| 2 — projector StatefulSet behind NATS durable consumers | done |
| 3 — Arrow IPC Tier 1.5 | partial (next round target) |
| 4 — URN + KEDA + NATS supercluster | not started |
| 5 — port/adapter payload store | partial |
| 6 — stage planner for fanout/reduce | **done (this round)** |

## Notes for next round

- **Phase 3** is the next target — wire `ArrowIpcSharedMemoryCache`
  (which exists at `noetl/core/storage/ipc_cache.py`) into the
  outbox publisher's payload-encoding path and the projector
  decoder's hot path. Both files already use Arrow Feather as the
  serialization format; the missing piece is `IpcHint` emission +
  consumption with graceful fallback to the durable read path.
- After Phase 3 lands, the natural sequence is Phase 5 (payload
  store port + adapters), then Phase 4 (URN + KEDA + supercluster).
