---
thread: 2026-05-22-phase3-ipc-observability
round: 1
from: claude
to: claude
created: 2026-05-22T21:20:44Z
status: open
expects_result_at: round-01-result.md
---

# Phase 3: surface IPC Tier 1.5 observability + verify round-trip preservation

> **Predecessor:** Phase 6 completed in
> `handoffs/archive/2026-05-22-phase6-stage-planner-wiring/`
> (noetl v2.91.0).

After re-surveying noetl `main` (sha `c7f3cbd5`), the v2 spec audit
table's "Phase 3 partial — no shared-memory cache" is **stale**:

- `noetl/core/storage/ipc_cache.py:31` — `ArrowIpcSharedMemoryCache`
  exists with put/get/sweep/delete + budget eviction + lease
  expiration.
- `noetl/core/storage/models.py:93` — `IpcHint` Pydantic model lives
  on `ResultRef.ipc` / `TempRef.ipc`.
- `noetl/core/storage/result_store.py:450` — `TempStore.get_ipc_bytes`
  reads through the IPC cache first, gracefully falls back to the
  durable read. Stats tracked at `self._ipc_stats` (admit/read/hit/
  miss/fallback counters).
- `noetl/worker/cursor_worker.py` — already stages frame outputs into
  the IPC cache before durable write.
- `noetl/server/api/frames/schema.py:13-44` — frame commit endpoint
  validates `output_ref` with IPC hints requires a durable companion
  ref.

The actual remaining Phase 3 work is **observability and
round-trip verification**:

1. `TempStore._ipc_stats` is tracked but **not exposed** to the
   projector metrics endpoint or any other Prometheus surface.
   Operators have no way to see hit ratios in production.
2. There are **no tests** verifying an `IpcHint` survives the
   round-trip through `frame.committed` → `noetl.event.payload_ref`
   → outbox JSONB → projector decode → resolved on the consumer
   side.
3. The audit table doesn't reflect the current state of Phase 3,
   so anyone reading it would think the cache doesn't exist. Stale
   doc.

## Background

### Verified existing surface

- [`noetl/core/storage/ipc_cache.py`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/ipc_cache.py)
  — full cache implementation, 173 lines.
- [`noetl/core/storage/models.py:93-141`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/models.py)
  — `IpcHint` model with `shm_name`, `schema_digest`, `byte_length`,
  `row_count`, `producer`, `node_id`, `lease_expires_at`,
  `media_type`. `is_expired()` helper.
- [`noetl/core/storage/result_store.py:450-475`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/result_store.py)
  — `TempStore.get_ipc_bytes(ref, *, ipc_cache=, allow_ipc=True)`
  with the fast-path / fallback logic and `_ipc_stats` updates.
- [`noetl/core/storage/result_store.py:990-1011`](https://github.com/noetl/noetl/blob/main/noetl/core/storage/result_store.py)
  — `_resolve_arrow_ipc_ref` + `_default_ipc_cache_for_ref` produce
  a per-ref cache instance keyed by the node id.
- [`noetl/worker/cursor_worker.py`](https://github.com/noetl/noetl/blob/main/noetl/worker/cursor_worker.py)
  — IPC cache wiring on the producer side (cursor frame outputs).
- [`noetl/server/api/frames/schema.py`](https://github.com/noetl/noetl/blob/main/noetl/server/api/frames/schema.py)
  — `FrameCommitRequest` enforces that any `output_ref` carrying an
  `ipc` hint must also include a durable reference.

### Gap 1: IPC stats invisible

```python
stats = default_store.get_ipc_stats()   # exists on TempStore
# but no Prometheus exporter consumes it.
```

The projector worker has its own `ProjectorMetrics` surface; the
broader server has its own. Neither pulls TempStore IPC stats. Wire
them through.

### Gap 2: no round-trip test for IpcHint

A worker that commits a frame with `output_ref.ipc` set, where the
event then mirrors through the outbox to the projector, should
result in the projector being able to dereference the IPC hint and
fast-path through the cache (when same-node) or fall back (when
not). No test exercises this end-to-end. Add one.

### Gap 3: stale audit doc

The ai-meta memory entry
`20260516-045607-distributed-runtime-event-store-v2-spec-authored.md`
called Phase 3 "Phase 3 Apache Arrow IPC Tier 1.5 zero-copy data
plane between Tier 1 in-process LRU and Tier 2 disk cache" — which
is exactly what's implemented. The earlier audit table I'm working
from said "partial; no shared-memory cache" — wrong. Refresh.

## Phases

### Phase A — design + drift check (no remote writes)

1. Re-verify the surface in "Background" against `origin/main`. Flag
   any drift since `c7f3cbd5`.
2. Decide the IPC metrics shape. Recommendation: add a small
   `IpcStatsSnapshot` typed dict in `noetl/core/storage/ipc_cache.py`
   (or a sibling helper module) with the existing counter names,
   plus a `get_default_ipc_stats()` module function the projector
   worker can import without coupling to `TempStore`'s internals.
3. Decide where the metrics export hooks fire from the projector
   worker. Recommendation: extend
   `noetl/core/projector/metrics.py`:`ProjectorMetrics.snapshot()`
   to pull `get_default_ipc_stats()` and include the counters in
   the Prometheus text export + `/summary` JSON, prefixed
   `noetl_ipc_*`.

### Phase B — implementation

4. **Expose TempStore IPC stats** —
   `noetl/core/storage/result_store.py`:
   - Promote `_ipc_stats` access to a public `get_ipc_stats()`
     method (returns a `dict[str, int]` snapshot).
   - Add a module-level `default_ipc_stats()` helper that returns
     `default_store.get_ipc_stats()` for callers that don't have a
     direct `TempStore` reference.

5. **Wire IPC counters into projector metrics** —
   `noetl/core/projector/metrics.py`:
   - Extend `render_projector_metrics` to call `default_ipc_stats()`
     and append:
     - `noetl_ipc_admit_attempts_total`
     - `noetl_ipc_admit_success_total`
     - `noetl_ipc_admit_failures_total`
     - `noetl_ipc_read_attempts_total`
     - `noetl_ipc_read_hits_total`
     - `noetl_ipc_read_misses_total`
     - `noetl_ipc_fallback_reads_total`
   - Same counters appear under `summary["ipc"]` in
     `projector_metrics_summary`.
   - Add derived ratios in the JSON summary:
     `ipc_admit_success_ratio`, `ipc_read_hit_ratio`.

6. **Make the IPC-stats import safe** — the storage import surface
   already exports `default_store`, but
   `noetl.core.projector.metrics` shouldn't drag in storage. Use a
   lazy module-level import inside the function that needs it so
   the metrics module stays importable from minimal-deps contexts
   (tests, the in-process metrics renderer).

### Phase C — tests

7. Add `tests/core/storage/test_ipc_stats_exposure.py`:
   - Confirm `TempStore.get_ipc_stats()` returns the expected
     counter set with zero values on a fresh instance.
   - Manually bump some counters via direct increment, then
     re-snapshot to confirm independence (no shared state across
     instances).

8. Add to `tests/core/test_projector_metrics.py`:
   - `test_projector_metrics_includes_ipc_counters_in_prometheus` —
     after exercising TempStore (admit a small Arrow payload, then
     read it back via `get_ipc_bytes`), call
     `render_projector_metrics` and assert the new metric names
     appear in the body with non-zero values.
   - `test_projector_metrics_summary_includes_ipc_block` — same
     setup, but assert `summary()["ipc"]["read_hit_ratio"]` and
     `summary()["ipc"]["admit_success_ratio"]` compute correctly.

9. Add `tests/server/api/frames/test_ipc_hint_round_trip.py`
   (new file):
   - Synthesize a `FrameCommitRequest` with both a durable
     `output_ref.ref` and an `output_ref.ipc` IpcHint.
   - Walk through `FrameCommitRequest.validate_output_ref_replay_authority`
     to confirm validation passes.
   - Build a synthetic event from the commit (mirror what
     `frames/endpoint.py:_insert_frame_event` would do at the
     `payload_ref` field) and feed it through the projector fold
     (`fold_replay_state`) to confirm the IpcHint is preserved in
     `state["frames"][<id>]["output_ref"]["ipc"]`.

### Phase D — wiki update

10. Update [`noetl/core/storage.md`](https://github.com/noetl/noetl/wiki/storage):
    - Promote the "Tier 1.5 — IPC shared-memory cache" subsection
      from "still in flight" / "future" to "live as of v2.91.x".
    - Add a "Stats and observability" subsection listing the new
      `noetl_ipc_*_total` counters and how to scrape them from the
      projector metrics endpoint.

11. Update [`noetl/projector.md`](https://github.com/noetl/noetl/wiki/projector):
    - Metrics table: add `noetl_ipc_admit_*`, `noetl_ipc_read_*`,
      `noetl_ipc_fallback_reads_total` rows.
    - `/summary` JSON example: include a sample `ipc` block.

12. Refresh
    `memory/inbox/2026/05/20260516-045607-distributed-runtime-event-store-v2-spec-authored.md`
    — no edit (memory is append-only); instead add a new memory
    entry titled "v2 spec Phase 3 audit refreshed" that records
    the actual state: data-plane done, observability + tests this
    round.

### Phase E — verify locally

13. Run `pytest` on the touched test files.
14. (Optional) Bring up local kind, run a small playbook that uses
    cursor frames, then curl the projector's `/summary` and
    `/metrics`. Confirm IPC counters show non-zero values.

### Phase F — open PR and merge

> ***Run only after explicit human go-ahead. Wait phrase: `merge phase 3`.***

15. Push branch `kadyapam/phase3-ipc-observability`, open noetl PR
    titled `feat(observability): expose IPC Tier 1.5 stats via
    projector metrics`. PR body references this handoff and the
    wiki commit.
16. Wait for CI / human review.
17. Merge with `--admin --merge --delete-branch` once approved.
18. Bump pointers in ai-meta: noetl + noetl-wiki.

## FINAL REPORT

Body sections — one H2 per Phase A–F, plus `## Issues observed`
and `## Manual escalation needed`.

## Hard rules

- Never push to `origin/main` on any repo unless this prompt says
  so. Phase F is the only step that pushes, gated by `merge phase 3`.
- Never force-push.
- Never merge PRs yourself before the gate phrase.
- Respect `agents/rules/wiki-maintenance.md` — the Phase D wiki
  edits ship paired with the code change.
- Do not store secrets in any file under ai-meta.
- If a step's preconditions aren't met, stop and write the report
  with `status: blocked` — don't improvise around blockers.
- **No payload-store port work in this round.** Phase 5 (payload
  store port + adapters) is a separate, larger round.
