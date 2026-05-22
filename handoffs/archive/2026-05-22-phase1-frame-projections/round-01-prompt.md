---
thread: 2026-05-22-phase1-frame-projections
round: 1
from: claude
to: claude
created: 2026-05-22T20:34:52Z
status: open
expects_result_at: round-01-result.md
---

# Phase 1: write per-frame projections from the projector worker

> **Predecessor:** none — first round. Sits inside the v2
> distributed-runtime spec phase 1 (frame-shaped cursor loops).
> Audit at
> https://github.com/noetl/docs/blob/main/docs/features/noetl_distributed_runtime_spec.md.

The runtime already has the frame model + claim API
([Frames](https://github.com/noetl/noetl/wiki/frames)). The
[projector](https://github.com/noetl/noetl/wiki/projector) currently
only writes one projection record per `execution_id`, even though the
fold kernel and replay API already accept `projection="frame"`. This
phase closes that gap: when the projector receives frame-related
events, it also writes per-frame projection records the dashboards
and replay tooling can read directly.

Scope is deliberately narrow — wire the existing fold + storage into
a parallel per-frame write path. No new tables. No new tools. No
schema migrations.

## Background

### Where to operate

- Primary repo: `repos/noetl/`. Branch off `origin/main` with
  `kadyapam/phase1-frame-projections`.
- Worktree isolation recommended (`isolation: worktree`).

### Existing surface

- Projector worker: [`noetl/core/projector/nats_worker.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/nats_worker.py),
  [`noetl/core/projector/service.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/service.py),
  [`noetl/core/projector/metrics.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/metrics.py).
- Replay fold kernel: [`noetl.server.api.replay.service.fold_replay_state`](https://github.com/noetl/noetl/blob/main/noetl/server/api/replay/service.py)
  with `projection` in (`execution`, `frame`, `loop`, `business_object`, `all`).
- Frames API events: [`noetl/server/api/frames/endpoint.py`](https://github.com/noetl/noetl/blob/main/noetl/server/api/frames/endpoint.py)
  emits `frame.claimed`, `frame.heartbeat`, `frame.committed` with
  `meta.frame_id` / `meta.stage_id` / `meta.parent_frame_id` /
  `meta.command_id` keys.
- Projection store: [`noetl.core.projection_store.PostgresProjectionStore`](https://github.com/noetl/noetl/blob/main/noetl/core/projection_store/postgres.py).
  Projection IDs are caller-defined strings; the upsert is
  version-monotonic.

### Current behavior

[`ReplayStateProjector.project()`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/service.py#L26)
groups events by `(tenant_id, organization_id, execution_id)`, folds
with `fold_replay_state(..., projection=self.projection)`, and writes
**one** `ProjectionRecord` with
`projection_id=f"execution/{execution_id}/{self.projection}"`.

When the projector is configured with `projection="frame"`, the fold
returns the frame surface but only stays grouped by execution. There
is no per-frame fan-out write.

## Phases

### Phase A — design + draft (no remote writes)

1. Reread the audit table in the most recent ai-meta session
   transcript (this prompt's analysis) and the v2 spec section on
   Phase 1.
2. Open the source files listed under "Existing surface". Confirm the
   current shapes match this prompt — flag any drift.
3. Draft the per-frame projection scheme:
   - `projection_id` shape: `frame/<frame_id>/<projection_kind>`.
   - `projection_type` shape: `replay_state:frame:<projection_kind>`
     (or `replay_state:frame` when the projector's own
     `projection="frame"` is in play).
   - `version` = the max `stream_version` of the frame's events.
   - `tenant_id` / `organization_id` / `execution_id` carried from
     the event (frame events ride the same execution).
   - `meta`: `frame_id`, `stage_id`, optional `parent_frame_id`,
     optional `command_id`, plus the existing `projection_lag_ms` /
     `event_count` / `event_time_watermark` fields the per-execution
     records already carry.
4. Decide whether per-frame writes happen in addition to the
   per-execution write or only when `projection ∈ {frame, all}`.
   Recommendation: **always** write per-frame records when the
   notification contains frame-shaped events, regardless of the
   projector's `projection` setting — that way operators don't need
   to run two projector worker instances to get both surfaces.

### Phase B — implementation

5. Extend `ReplayStateProjector` to:
   - Identify frame-shaped events in the incoming batch (events whose
     `event_type` starts with `frame.` or whose `meta` carries a
     `frame_id`).
   - Group them by `(tenant_id, organization_id, execution_id, frame_id)`.
   - Fold each group via `fold_replay_state(..., projection="frame")`
     against the frame-scoped slice of events.
   - Build a `ProjectionRecord` per group with the IDs from the design
     phase, then `save_projection(...)`. Use the same
     monotonic-version semantics already in use.
6. Wire metrics ([`metrics.py`](https://github.com/noetl/noetl/blob/main/noetl/core/projector/metrics.py)):
   - Add `frame_projection_records_total` counter.
   - Add `frame_projection_stale_records_total` (records where the
     version-monotonic upsert skipped the write).
   - Add the counters to both the Prometheus text export and the
     `/summary` JSON.
   - Update `record_notification` (or add `record_frame_notification`)
     so the projector worker increments the new counters.
7. The per-execution path is unchanged — same group, same record. The
   per-frame path is **additive**.

### Phase C — tests

8. Extend `tests/core/test_replay_state_projector.py` (or add a sibling
   `test_frame_projection.py`):
   - Synthetic event sequence with `frame.claimed` →
     `frame.heartbeat` → `frame.committed` for one frame; assert one
     `frame/...` projection record is written with the expected IDs
     and a non-empty state.
   - Two concurrent frames in one execution → two records, distinct
     `projection_id`s.
   - Re-running the same projector call → second pass is a no-op
     (`save_projection` returns `False`).
   - A notification with no frame events → no `frame/...` records
     written, per-execution record still written.
9. Extend `tests/core/test_projector_metrics.py` to cover the new
   counters.

### Phase D — wiki update (per `agents/rules/wiki-maintenance.md`)

10. Update [`noetl/projector.md`](https://github.com/noetl/noetl/blob/main/noetl-wiki/noetl/projector.md)
    in `repos/noetl-wiki/`:
    - Add a "Frame projections" subsection under the existing
      sections covering the new `projection_id` shape, metric names,
      and the additive behavior.
    - Update the [Frames](https://github.com/noetl/noetl/wiki/frames)
      Related list if it doesn't already cross-link.
11. Push the wiki commit (`master`), then bump the noetl-wiki pointer
    in ai-meta in the same change set as the noetl PR pointer bump
    (per the wiki-maintenance rule).

### Phase E — verify locally

12. Bring up the local kind cluster via the ops playbook documented
    in `agents/rules/ops-deploy.md`:
    `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`.
13. Run a small playbook that exercises frame claim/commit (an
    existing GLUT playbook with `loop.cursor` is sufficient).
14. Query `noetl.projection`:
    `SELECT projection_id, projection_type, version, meta FROM noetl.projection WHERE projection_id LIKE 'frame/%' ORDER BY updated_at DESC LIMIT 20;`
15. Confirm per-frame rows exist with the expected shape.
16. Curl `:9100/summary` on the projector pod; confirm the new
    counters increment.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 1`.***

17. Push the branch, open a noetl PR titled
    `feat(projector): write per-frame projections`. PR body references
    this handoff path and the updated wiki page.
18. Wait for CI / human review.
19. Merge with `--admin --merge --delete-branch` once approved.
20. Bump pointers in ai-meta: one commit each for `noetl` and
    `noetl-wiki`. Push.

## FINAL REPORT

Always emit `round-01-result.md` even on early STOP. Frontmatter:

```yaml
---
thread: 2026-05-22-phase1-frame-projections
round: 1
from: claude
to: claude
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Body sections:

```markdown
## Phase A — design + draft
- design notes, any prompt drift flagged

## Phase B — implementation
- file diffs (paths + short description), commit SHA, line counts

## Phase C — tests
- test file paths, what each test covers, pytest output excerpt

## Phase D — wiki update
- noetl-wiki commit SHA, page diffs

## Phase E — verify locally
- kind redeploy output excerpt, sample SQL rows, /summary curl
  excerpt

## Phase F — open PR and merge
- PR URL, merge commit SHA, ai-meta pointer-bump commits

## Issues observed
- bullet list with grep-able fingerprints

## Manual escalation needed
- any commands the human must run
```

## Hard rules

- Never push to `origin/main` on any repo unless this prompt
  explicitly says so. Phase F is the only step that pushes, and it's
  gated by `merge phase 1`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `AGENTS.md` and rules under `agents/rules/`.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the report
  with `status: blocked` — don't improvise around blockers.
- Wiki page update (Phase D) is part of "done" per
  `agents/rules/wiki-maintenance.md` rule #1 — frame projections is
  new behavior on the projector, so the wiki must move with the code.
