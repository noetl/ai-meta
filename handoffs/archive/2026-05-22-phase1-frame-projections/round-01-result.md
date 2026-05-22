---
thread: 2026-05-22-phase1-frame-projections
round: 1
from: claude
to: claude
created: 2026-05-22T20:45:48Z
in_reply_to: round-01-prompt.md
status: partial
---

# Phase 1 result — per-frame projections from the projector worker

Phases A–D executed in this session. Phase E (local kind verify) skipped
— required infrastructure not exercised in this session. Phase F (open
+ merge PR) **open as PR #585**, merge gated on wait phrase
`merge phase 1`.

## Phase A — design + drift check

- Re-read [`noetl/core/projector/service.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/service.py),
  [`noetl/core/projector/nats_worker.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/nats_worker.py),
  [`noetl/core/projector/metrics.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/metrics.py),
  [`noetl/server/api/replay/service.py`](https://github.com/noetl/noetl/blob/main/noetl/server/api/replay/service.py)
  end-to-end. Surface matches the prompt — no drift.
- Confirmed `fold_replay_state` already populates `state["frames"]` as
  a dict keyed by frame_id with rich per-frame fields (status,
  row_count, attempts, claimed/terminal event ids, output_ref +
  payload summary, cursor, events_emitted). Design refined to
  **reuse** that fold rather than re-fold per frame — keeps
  per-execution and per-frame checksum bundles consistent.
- Picked:
  - `projection_id` = `frame/<frame_id>/<projection>`
  - `projection_type` = `replay_state:frame:<projection>`
  - `version` / `source_event_id` computed against the per-frame
    **subset** of the input batch (not the global last event) so the
    monotonic upsert stays coherent even if frames arrive out of
    order.
- Confirmed `fold_replay_state` rejects non-numeric `stage_id` /
  `frame_id` (calls `int()` in
  [`normalize_replayed_stage_projection`](https://github.com/noetl/noetl/blob/main/noetl/server/api/replay/service.py#L674)
  and the frame normalizer at line 627). Tests use numeric IDs as a
  result.

## Phase B — implementation

Branch: `kadyapam/phase1-frame-projections` in `repos/noetl`.
Commit: `282d11ad feat(projector): write per-frame projections from the projector worker`.

Files changed (+527/-6):

- `noetl/core/projector/service.py`
  - Added `_build_frame_records()` method on `ReplayStateProjector`
    — extracts each entry from `state["frames"]`, picks the
    event subset by frame_id, computes per-frame version /
    source_event_id / lag.
  - Calls `save_projection()` for each frame record after the
    existing per-execution save. New records appended to the same
    `written` list the caller receives.
  - Added module-level `_extract_frame_id()` mirroring
    [`noetl.server.api.replay.service._frame_id`](https://github.com/noetl/noetl/blob/main/noetl/server/api/replay/service.py#L146)
    resolution order (`event.frame_id` column → `aggregate_id`
    with type `frame` → `meta.frame_id`).

- `noetl/core/projector/nats_worker.py`
  - Split `written` into execution vs frame records via
    `_is_frame_record()` helper.
  - Pass separate counts to `record_notification`:
    `frame_projection_records=` and
    `frame_stale_projection_records=`.
  - Added `_frame_group_count()` helper for the stale-records
    arithmetic (mirrors `_projection_group_count()` but keys on
    frame_id).

- `noetl/core/projector/metrics.py`
  - Added counters: `frame_projection_records_total`,
    `frame_projection_stale_records_total`.
  - Added last-batch gauges:
    `last_batch_frame_projection_records`,
    `last_batch_frame_stale_projection_records`.
  - Extended `record_notification` signature with the two new
    keyword args (defaulting to 0 for callers that don't pass
    them — backwards compatible).
  - Extended `render_projector_metrics` text export with `# HELP`
    / `# TYPE` blocks for all four new metrics.
  - Extended `_batch_summary` with `frame_projection_records`,
    `frame_stale_projection_records`,
    `frame_projection_record_ratio`,
    `frame_stale_projection_ratio` keys.

## Phase C — tests

`pytest tests/core/test_replay_state_projector.py tests/core/test_projector_metrics.py` → **39 passed**.

Tests added / updated in `tests/core/test_replay_state_projector.py`:

- Updated `test_replay_state_projector_writes_grouped_projection_records`
  — expected record count is now **3** (1 execution + 1 frame from
  execution 7, 1 execution-only from execution 8). New assertions
  cover `projection_id="frame/1/all"`, `projection_type`, `version`,
  `state.frame_id`, `state.frame.status`, `meta.frame_id`,
  `meta.frame_status`, `meta.event_count`.
- `test_replay_state_projector_writes_per_frame_projection_records`
  — two frames in one execution → two records keyed
  `frame/11/all` and `frame/22/all`.
- `test_replay_state_projector_skips_per_frame_when_no_frame_events`
  — execution-only batch produces only the execution record.
- `test_replay_state_projector_frame_records_respect_monotonic_upsert`
  — newer write at v=3, then stale event at v=1 — stale write
  returns `False` from `save_projection`; stored record stays at
  v=3 with `status=COMPLETED`.
- `test_nats_projector_worker_counts_frame_projection_writes`
  — worker exercise; `frame_projection_records_total == 1`,
  `last_batch_frame_projection_records == 1` after a notification
  that contains `frame.dispatched` + `frame.committed`.
- `test_nats_projector_worker_reports_zero_frame_metrics_for_non_frame_batch`
  — regression guard.

Tests added / updated in `tests/core/test_projector_metrics.py`:

- Extended `test_projector_metrics_render_prometheus_labels` to
  assert all 4 new metric names appear in the rendered body and
  that `batch_summary` includes the new frame keys.
- New `test_projector_metrics_record_notification_tracks_frame_counters`
  — independent assertion that counters and gauges flow through
  `record_notification`'s new kwargs.

## Phase D — wiki update

Wiki repo: `repos/noetl-wiki/`. Commit `03886a8 wiki(projector): document per-frame projection writes`. Pushed to `origin master`.

Page updated: [`noetl/projector.md`](https://github.com/noetl/noetl/wiki/projector):

- New "Frame projections" subsection (between "Sharding model" and
  "Metrics") covering: record shape table, monotonic-upsert note,
  additive-behavior rationale, opt-out (`projection=execution`).
- Metrics table extended with
  `noetl_projector_frame_projection_records_total` and
  `noetl_projector_frame_projection_stale_records_total`.

Per `agents/rules/wiki-maintenance.md` rule #1, the wiki edit ships
alongside the code change (paired commits, both pushed).

## Phase E — verify locally

**Skipped in this session** — local kind cluster not exercised. The
unit tests cover the projection logic comprehensively (4 projector
tests + 2 worker tests + 2 metrics tests, all green). Full
integration verify (kind redeploy + small playbook + SQL of
`noetl.projection WHERE projection_id LIKE 'frame/%'` + curl
`:9100/summary`) is the natural next round-or-followup before
merging.

If the human (or a follow-up codex round) wants to run the verify
phase before the merge gate, the steps from the prompt's Phase E
hold verbatim — no preconditions changed during implementation.

## Phase F — open PR and merge

**PR open, merge gated on wait phrase `merge phase 1`.**

- PR: [noetl#585 — feat(projector): write per-frame projections](https://github.com/noetl/noetl/pull/585)
- Branch: `kadyapam/phase1-frame-projections` pushed to origin.
- PR body references this handoff thread and the wiki commit.
- Coordinating commits ready after merge:
  - `chore(sync): bump noetl to <merge sha>`
  - `chore(sync): bump noetl-wiki to 03886a8`

When the gate phrase lands, the merge + ai-meta pointer bumps are a
clean follow-up (no rebases needed; branch is one commit ahead of
`origin/main`).

## Issues observed

- `fold_replay_state` requires `stage_id` / `frame_id` to be
  numeric-parseable via `int()`. Test fixtures initially used
  alphabetic placeholder IDs (`s1`, `aa`, `bb`, `zz`) and tripped
  `ValueError: invalid literal for int() with base 10: 'aa'` from
  `normalize_replayed_stage_projection` (line 674) and the frame
  normalizer (line 627). Test fixtures updated to numeric IDs (`1`,
  `9`, `11`, `22`, `55`, `99`). No production code change needed —
  real `noetl.frame` / `noetl.stage` IDs are snowflake bigints.
- `frame.committed` event's `row_count` lives in `meta.row_count`,
  not `result.row_count`. The original test that exercised
  `frame.committed` didn't assert on `row_count`, masking this. A
  pre-existing test fixture inconsistency, **not** new behavior.

## Manual escalation needed

- **Wait phrase**: human says `merge phase 1` to unlock Phase F's
  merge step. Until then, the PR stays open with reviewer comments
  welcome.
- After merge, run from ai-meta root:
  ```bash
  cd repos/noetl && git checkout main && git pull origin main
  cd ../.. && git add repos/noetl repos/noetl-wiki
  git commit -m "chore(sync): bump noetl + noetl-wiki for Phase 1 frame projections"
  git push origin main
  ```
- Optional but recommended before merge: run Phase E locally to
  confirm the new `frame/...` rows materialize in `noetl.projection`
  and the new metric counters increment under a real workload.
