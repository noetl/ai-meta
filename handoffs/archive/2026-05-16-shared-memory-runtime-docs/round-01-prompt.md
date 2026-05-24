---
thread: 2026-05-16-shared-memory-runtime-docs
round: 1
from: codex
to: claude
created: 2026-05-16T14:28:03Z
status: open
expects_result_at: round-01-result.md
---

# Review shared-memory runtime docs update

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read this prompt cold; do not rely on chat history. This handoff is about a docs-only update to the NoETL distributed runtime spec after `noetl/docs#75` merged.

The user's architectural direction is: shared memory should be a core advantage of the system, but event sourcing is the temporal kernel. NoETL is becoming a distributed business operating system for multitenant organizations, with state reproducible at a requested time from actual event data plus immutable payloads. The spec should describe algorithms and contracts, not bind NoETL to specific analytical or streaming products.

## Background

- `ai-meta` repo root: `/Volumes/X10/projects/noetl/ai-meta`
- Docs submodule path: `/Volumes/X10/projects/noetl/ai-meta/repos/docs`
- Spec file: `repos/docs/docs/features/noetl_distributed_runtime_spec.md`
- PR #75 in `noetl/docs` is already merged into docs `main` as `053909e251671f044870f21cb50ea1c9acd40a39`.
- Codex fast-forwarded the local docs submodule from stale `2c42a9a` to merged `053909e` before editing.
- Codex created docs branch `kadyapam/shared-memory-event-sourcing-runtime`.
- Docs commit pushed to `noetl/docs`:
  - `1a9b72e12ee4b8320df8cd729ec1bc9093d8eca8`
  - message: `docs(features): strengthen event-sourced shared memory runtime`
  - branch: `origin/kadyapam/shared-memory-event-sourcing-runtime`
- `ai-meta` `main` was updated and pushed with the submodule pointer:
  - `8a9eb984...` (verify exact full SHA locally)
  - message: `chore(sync): bump docs to shared memory runtime spec`
- Important user correction during drafting: do not name ClickHouse or RisingWave in this spec. Describe the underlying distributed-data algorithms, indexes, columnar analytical projections, streaming materialized views, actor/barrier checkpointing, LSM-style cache behavior, etc. Product choices are deployment-specific.
- Codex verified:
  - `git diff --check -- docs/features/noetl_distributed_runtime_spec.md` passed in `repos/docs`.
  - `rg -n "ClickHouse|RisingWave|risingwave|clickhouse|Hummock" docs/features/noetl_distributed_runtime_spec.md` returned no matches.

## What changed in the spec

- Renamed/reframed the spec as `NoETL Distributed Runtime + Event-Sourced Shared Memory Spec`.
- Made event sourcing the system kernel: canonical append-only event log plus immutable payloads are the authority.
- Added a required event envelope with tenant/org scope, stream/aggregate ids, schema metadata, causation/correlation ids, idempotency key, and payload refs.
- Added time-travel/replay semantics and replay parity as a release gate.
- Reframed shared memory as a rebuildable shared-state fabric: in-process cache, Arrow IPC shm/memfd, local disk/NVMe, distributed K/V, streaming materialization, columnar analytical projections, and indexes.
- Added deterministic serialization rules: canonical JSON envelope, Arrow IPC tabular payloads, schema upcasters, digest/checksum behavior, decimal/time handling, and Python/Rust parity corpus.
- Added multitenant distributed business OS surfaces: tenant/org resource locator, cache key isolation, projection isolation, replay scope, and quantum-cloud posture for heterogeneous/specialized workers.
- Updated rollout phases so Phase 0 includes envelope validation and replay harness, and later adapter work includes replay parity suites.

## Phases

### Phase A — review current state (no remote writes)

1. In `/Volumes/X10/projects/noetl/ai-meta`, run:
   - `git status --short`
   - `git log --oneline -3`
   - `git submodule status --recursive repos/docs`
2. In `/Volumes/X10/projects/noetl/ai-meta/repos/docs`, run:
   - `git status --short`
   - `git branch --show-current`
   - `git log --oneline -5`
   - `rg -n "ClickHouse|RisingWave|risingwave|clickhouse|Hummock" docs/features/noetl_distributed_runtime_spec.md`
3. Read `docs/features/noetl_distributed_runtime_spec.md` and review for:
   - product-neutral language;
   - event sourcing as the replay authority;
   - shared memory/cache as a core advantage but rebuildable from events;
   - serialization completeness;
   - multitenant organization isolation;
   - consistency with existing neighboring specs.
4. If you find small docs issues, patch them locally in `repos/docs`. Keep edits scoped to `docs/features/noetl_distributed_runtime_spec.md` unless a neighboring doc has an unavoidable contradiction.
5. If you patch anything, run:
   - `git diff --check -- docs/features/noetl_distributed_runtime_spec.md`
   - the product-name `rg` above.

### Phase B — prepare publication recommendation (no remote writes)

1. Decide whether the docs branch should become a PR against `noetl/docs:main` as-is, needs another docs patch first, or should be abandoned/reworked.
2. If a PR should be opened, draft the PR title/body in your result file. Do not open the PR unless the human explicitly asks in chat outside this prompt.
3. If you made local patches, commit them in `repos/docs` with a docs-scoped message, but do not push unless the human explicitly asks in chat outside this prompt.
4. If you commit a new docs SHA, note that `ai-meta` will need a follow-up submodule pointer bump; do not update or push `ai-meta` unless the human explicitly asks.

## FINAL REPORT

Always emit this, even on early STOP. Write it as the body of `round-01-result.md` with frontmatter:

```yaml
---
thread: 2026-05-16-shared-memory-runtime-docs
round: 1
from: claude
to: codex
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Then the report markdown:

```markdown
## Phase A — review current state
- Current ai-meta HEAD and docs submodule SHA.
- Current docs branch/HEAD.
- Product-name grep result.
- Any edits made, with commit SHA if committed.

## Phase B — publication recommendation
- Recommendation: open PR / patch first / rework / abandon.
- Draft PR title/body if applicable.
- Whether ai-meta needs another submodule pointer update.

## Issues observed
- Bullet list of anything surprising. Include grep-able fingerprints such as exact error strings or SHAs.

## Manual escalation needed
- Any action that needs human approval, with exact command(s) if useful.
```

## Hard rules for this thread

- This repo is public. Do not write secrets, tokens, customer data, or sensitive values.
- Do not edit product code in `ai-meta`; this thread is docs/orchestration only.
- Do not force-push.
- Do not merge PRs.
- Do not push `ai-meta` or `noetl/docs` unless the human explicitly asks after reading this prompt.
- Do not reintroduce product names for analytical or streaming engines in this spec.
- Respect `AGENTS.md`, `handoffs/README.md`, and `agents/rules/handoffs.md`.
