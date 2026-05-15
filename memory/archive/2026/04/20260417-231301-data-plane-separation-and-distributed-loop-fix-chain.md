# Data Plane Separation + Distributed Loop Fix Chain (April 17 2026)
- Timestamp: 2026-04-17T23:13:01Z
- Author: Kadyapam
- Tags: noetl,architecture,data-plane,reference-only,risingwave,loop,distributed,pft,bugfix-chain

## Summary

Two major deliverables in this session:

1. **Distributed loop bug fix chain (#1–#9)** — nine sequential fixes addressing the test_pft_flow stall at every stage of the facility × patient × data-type loop pipeline. Each fix exposed the next bug behind it.

2. **Data plane separation (RisingWave-inspired)** — architectural change that moves Postgres result rows from event context variables into persistent TempStore, passing only compact references through the control plane. This eliminates the root cause of the entire fix chain: inline row data that bloats events, breaks cold-state rebuilds, causes synthetic collection races, and violates the reference-only contract.

## Fix Chain Summary

| # | Commit | Bug | Fix |
|---|---|---|---|
| 1 | `0d380689` | NATS KV `max(existing, incoming)` preserves old epoch's `completed_count=100` on reset | `force_replace=True` on `set_loop_state` |
| 2 | `79abbdee` | Async batch acceptance lag → `completed_steps` stale → re-entrant step suppressed | DB authority check (`command.completed` count) before suppression |
| 3 | `e74fd9a9` | Epoch ID `loop_..._1` reused on natural re-entry → `loop.done` unique index deduplicates | `attempt = COUNT(loop.done) + 1` from DB |
| 4 | `d2ad24d9` | Cold render fails → empty collection → `loop.done` threshold unreachable | Synthetic collection from NATS KV `collection_size` |
| 5 | `2b9dca28` / `85d9c0da` | Synthetic int placeholders replace real patient rows → raw Jinja leaks into SQL | Persist + restore real collection from NATS KV |
| 6 | `ccbf6f6f` / `7116fba0` | Main pool (16) exhausted by parallel dispatch → checkpointer/sweeper PoolTimeout | Dedicated bg pool (max=4) + main pool bumped to 32 |
| 7 | `b2b15ace` | `_normalize_replay_result` only hydrates top-level `reference` shape | Call `_hydrate_reference_only_step_result` during replay |
| 8 | `17caba04` | Nested `result.reference` and `data.reference` not hydrated during replay | `_hydrate_all_reference_shapes` covering 3 envelope shapes |
| 9 | `63f82946` | `step_results` on rebuilt state carry reference-only envelope → `TaskResultProxy` missing `.rows` | Promote context keys to top level in `mark_step_completed` |

Additional fixes during validation:
- `18d80457` — server `_STRICT_RESULT_ALLOWED_KEYS` rejected `meta`/`parent_ref` in result envelope
- `1521af08` — playbook `set` storing `{{ output.data }}` blob → changed to scalar `{{ output.status }}`
- `99c6ee8e` — `BatchEventItem` missing `meta` field (user fix)
- `7432ad18` — save loop collection in `transitions.py` at dispatch time (all loop steps)
- `34deb7fe` — unblock `rows`/`columns` in `_extract_control_context` (workaround, later replaced by data plane separation)

## Data Plane Separation (noetl `df0a9e45`)

**Architecture change** inspired by RisingWave's data/control plane split:

**Before:** Postgres tool → inline `{rows, row_count, columns}` → event.result → context variables → `{{ step.rows }}` in loop.in template

**After:** Postgres tool → persist rows to TempStore → `{status, reference: {kind, ref, store}, context: {row_count, columns}}` → event.result → loop.in resolves reference → fetch rows from storage

### Phase 1 — Postgres tool externalization
- `tools/postgres/executor.py`: new `_externalize_rows_to_store()` — persists SELECT result rows to TempStore via `default_store.put()`, returns reference envelope. Falls back to inline if TempStore unavailable.

### Phase 2 — Loop collection resolver
- `common.py`: new `_resolve_collection_if_reference()` async helper — detects reference-bearing dicts and resolves via `TempStore.resolve()`.
- Wired into `transitions.py`, `rendering.py`, `commands.py` — after rendering `loop.in` template, before `_normalize_loop_collection`.

### Phase 3 — Transparent `.rows` resolution
- `state.py`: `mark_step_completed` → `async`. Eagerly resolves `reference` with `kind=temp_ref` and caches `rows` in step_results dict.
- `events.py` (10 sites) + `store.py` (1 site): all callers updated to `await`.
- `{{ claim_patients.rows }}` works without playbook changes.

### Phase 4 — Re-block rows/columns in context extraction
- `nats_worker.py`: `rows`/`columns` back in `blocked_keys`. Reference dicts with `kind=temp_ref` pass through.

### Invariant
No playbook DSL changes required. `{{ claim_patients.rows }}` continues to work via transparent reference resolution at `mark_step_completed` time. The rows live in-memory in `step_results` only — never in the event payload.

## Colima Migration (earlier in session)

- Docker Desktop → Colima on external SSD (`/Volumes/X10/colima-home`, 6 CPU / 12 GB / 200 GB)
- Docker CLI v29.4 (Homebrew) replacing Docker Desktop v24
- Buildx v0.33 (Homebrew) replacing v0.11
- Ops playbook colima status guard fixed for v0.10+ output format

## Configuration

New/changed env vars:
- `NOETL_POSTGRES_POOL_MAX_SIZE` default 32 (was 16)
- `NOETL_BG_POOL_MIN_SIZE` default 1, `NOETL_BG_POOL_MAX_SIZE` default 4 (new dedicated bg pool)
- `NOETL_SHARD_COUNT` 2 for local kind (16 default is too heavy for dev)

## Repos

- repos/noetl `df0a9e45` — data plane separation + full fix chain
- repos/docs `cd6024f` → needs update with data plane separation doc
- repos/ops — colima guard fixes

## Related

- Prior memory: `20260416-065402-noetl-async-sharded-redesign.md`
- Prior memory: `20260416-142730-noetl-async-sharded-followups-completed.md`
- Prior memory: `20260417-034244-colima-migration-and-envelope-fix-deployed.md`
- Design doc: `repos/docs/docs/features/noetl_async_sharded_architecture.md`
- Reference-only PRD: `repos/docs/docs/features/reference-only-event-results-prd.md`
- Bug reports: `sync/issues/2026-04-16-bug-pft-*`, `sync/issues/2026-04-17-bug-*`
