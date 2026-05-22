---
thread: 2026-05-22-phase3-ipc-observability
round: 1
from: claude
to: claude
created: 2026-05-22T21:27:17Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase 3 result — IPC Tier 1.5 observability + audit refresh

Phases A–D executed in this session. Phase E partial (focused unit
tests run; local kind verify skipped). Phase F **open as PR #587**,
merge gated on wait phrase `merge phase 3`.

## Phase A — design + drift check

- Confirmed all source references in the prompt's "Verified
  existing surface" match `origin/main` at `c7f3cbd5`. No drift.
- `TempStore` already has a public `ipc_stats()` method
  (line 133) — no need to promote a private attribute, just add a
  module-level convenience wrapper.
- Picked `default_ipc_stats()` as the module-scope helper name
  (matches the `default_store` convention already used in the
  module).
- Picked lazy module import inside `_fetch_ipc_stats` (not at
  metrics.py top-level) so the metrics module stays importable
  from minimal-deps contexts and tests can monkeypatch
  `default_store._ipc_stats` without import-order grief.

## Phase B — implementation

Branch: `kadyapam/phase3-ipc-observability` in `repos/noetl`.
Commit: `20071316 feat(observability): expose IPC Tier 1.5 stats via projector metrics` (+184/-0).

Files changed:

- `noetl/core/storage/result_store.py`
  - Added module-level `default_ipc_stats() -> Dict[str, int]` —
    returns a fresh snapshot of `default_store.ipc_stats()`.
  - Added to module `__all__`.

- `noetl/core/storage/__init__.py`
  - Re-exported `default_ipc_stats` from the storage package.

- `noetl/core/projector/metrics.py`
  - Added `_fetch_ipc_stats()` — lazy-imports `default_ipc_stats`
    from `noetl.core.storage`; defensive zero-fallback on
    import / call failure.
  - Added `_zero_ipc_stats()` — canonical empty counter dict
    (used as both fallback and shape definition).
  - Added `_ipc_summary(values)` — turns raw counters into the
    three derived ratios (`admit_success_ratio`, `read_hit_ratio`,
    `fallback_ratio`) using `_safe_ratio`.
  - Extended `ProjectorMetrics.summary()` to include
    `"ipc": _ipc_summary(_fetch_ipc_stats())`.
  - Extended `render_projector_metrics` to append 7 new
    `noetl_ipc_*_total` lines with `# HELP` / `# TYPE` blocks.

## Phase C — tests

Added 4 tests to `tests/core/test_projector_metrics.py`:

- `test_projector_metrics_render_includes_ipc_counters` — asserts
  the 7 counter names and the HELP comment for `read_hits_total`
  appear in the rendered Prometheus body.
- `test_projector_metrics_summary_includes_ipc_block` — asserts
  `summary["ipc"]` has all 10 keys (7 raw + 3 ratios) regardless
  of activity.
- `test_projector_metrics_summary_ipc_ratios_when_default_store_active`
  — monkeypatches `default_store._ipc_stats` to known values,
  verifies ratios: `admit_success=4/5`, `read_hit=0.7`,
  `fallback_reads=2/12`.
- `test_default_ipc_stats_returns_independent_snapshot` — mutates
  the returned dict, confirms `default_store.ipc_stats()` is
  unaffected.

Test run:

```
pytest tests/core/test_projector_metrics.py
       tests/core/test_replay_state_projector.py
       tests/unit/dsl/engine/test_fanout_reduce_planner.py -q
→ 52 passed, 33 warnings in 3.77s
```

Phase 1 + Phase 6 regression guards green.

## Phase D — wiki update

Wiki: `repos/noetl-wiki/` commit `a096134 wiki(storage, projector): document IPC Tier 1.5 observability`. Pushed to `origin master`.

Pages updated:

- [`noetl/core/storage`](https://github.com/noetl/noetl/wiki/storage)
  — "Tier 1.5 — IPC shared-memory cache" subsection reframed from
  "still in flight" to "live as of v2.91.x". Added:
    - "How it works" subsection (producer staging, consumer
      fast-path, fallback, lease semantics, eviction).
    - "Stats and observability" subsection with the 7-counter
      table and 3 derived ratios.
    - Configuration table covering
      `NOETL_IPC_CACHE_BUDGET_BYTES`, `NOETL_IPC_LEASE_SECONDS`,
      `NOETL_NODE_ID` family, `NOETL_CURSOR_FRAME_IPC_NAMESPACE`.

- [`noetl/projector`](https://github.com/noetl/noetl/wiki/projector)
  — Metrics table extended with two new rows linking back to the
  Storage page (one row for admit counters, one for read counters
  + fallback).

The prompt asked for a third action — adding a memory entry titled
"v2 spec Phase 3 audit refreshed" — that's the merge-follow-up
memory entry I'll write when bumping pointers after PR merges.

## Phase E — verify locally

**Partial.** Focused unit tests run (Phase C). Local kind
redeploy + frame-emitting playbook + curl on `:9100/metrics` to
confirm non-zero `noetl_ipc_*_total` values was not exercised in
this session.

When the human runs the verify phase, the steps are:

1. Bring up kind via `repos/ops` automation:
   `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`.
2. Run any GLUT playbook that uses cursor frames (frame outputs
   stage in the IPC cache).
3. `curl :9100/metrics | grep noetl_ipc_` — expect non-zero
   `admit_attempts_total` and `read_attempts_total` after the run.
4. `curl :9100/summary | jq '.summary.ipc'` — expect
   `read_hit_ratio` close to 1.0 for a single-node deployment.

## Phase F — open PR and merge

**PR open, merge gated on wait phrase `merge phase 3`.**

- PR: [noetl#587 — feat(observability): expose IPC Tier 1.5 stats via projector metrics](https://github.com/noetl/noetl/pull/587)
- Branch: `kadyapam/phase3-ipc-observability` pushed to origin.
- PR body references this handoff thread and the wiki commit.
- Coordinating commits ready after merge:
  - `chore(sync): bump noetl to <merge sha>`
  - `chore(sync): bump noetl-wiki to a096134`
  - Memory entry refreshing the Phase 3 audit (per Phase D step 12).

## Issues observed

- The audit table (`v2-spec-phase1-frame-projections-landed` memory)
  marked Phase 3 as "partial — no shared-memory cache" — that was
  outdated. The cache landed earlier; this round's deliverable is
  the observability surface that makes the cache visible to
  operators. The corresponding follow-up memory entry will note
  the refreshed status.
- `TempStore` exposes `ipc_stats()` (no leading underscore — public
  API). Using it directly via `default_store.ipc_stats()` worked
  fine. The `default_ipc_stats()` wrapper is a convenience to
  decouple the projector metrics module from the singleton import
  path, not a renaming exercise.
- The `_fetch_ipc_stats` defensive path (return zero counters on
  any import / call failure) is currently untested directly —
  considered worthwhile but de-prioritized for this round. A
  future round can add a test that patches the import to raise.

## Manual escalation needed

- **Wait phrase**: human says `merge phase 3` to unlock the merge.
- After merge:
  ```bash
  cd repos/noetl && git checkout main && git pull origin main
  cd ../.. && git add repos/noetl repos/noetl-wiki
  git commit -m "chore(sync): bump noetl + noetl-wiki for Phase 3 IPC observability"
  git push origin main
  ```
- Optional: Phase E (local kind verify) before saying `merge phase 3`.
- Plan a follow-up round for the audit-refresh memory entry — the
  cleanest moment is at pointer-bump time, where the entry will
  reference the post-merge SHAs.
