---
thread: 2026-05-26-noetl-inline-trivial-children
round: 2
from: codex
to: claude
created: 2026-05-26T04:17:01Z
in_reply_to: round-02-prompt.md
status: complete
---

## Phase A — sync

- Synced `repos/noetl` to `main` at `019a9457c67dc112d864cbe3c9349e7068cc9af8`.
- Confirmed PR #607 is present on main.
- Synced `repos/noetl-wiki` to `master` at `3900e2ce665d86e3d2bf63abb039b3285ab464dd`.
- Created `repos/noetl` branch `kadyapam/inline-trivial-children-round-a`.
- Re-read `round-01-result.md`; the approved audit/design still applies. The current branch line numbers shifted after the Round A helper insertion, but the execution boundaries did not change.

## Phase B — detector module

- Added pure detector module `noetl/core/workflow/playbook/inline_execution.py`.
- Added `InlineDecision` with `inline`, `reasons`, `depth`, and `mode`.
- Implemented the approved predicates: `framework=noetl`, depth <= 3, workflow length 1..3, metadata opt-in or allow-list, allowed tool kinds only, no callback/async/output-ref/finalizer/cursor/parallel/distributed-loop/nested-agent/nested-playbook cases, and tenant/org matching.
- Added default allow-list `automation/agents/mcp/*` plus `NOETL_INLINE_TRIVIAL_CHILDREN_ALLOW_LIST` CSV override.
- Added unit tests in `tests/core/workflow/test_inline_execution.py` covering 24 detector cases.

## Phase C — dry-run wiring

- Updated `noetl/tools/agent/executor.py` only in the NoETL agent bridge.
- Added `NOETL_INLINE_TRIVIAL_CHILDREN` modes:
  - `off`: skip detector entirely.
  - `dry_run`: compute a decision, log at `DEBUG`, attach `meta.inline_decision`, then continue the existing dispatch.
  - `enforce`: return `agent.configuration` error with "Round B not yet implemented".
- Preserved the current `/api/execute` + NATS child dispatch path.
- Added agent executor tests for `off`, `dry_run`, and `enforce`.
- Did not touch `noetl/core/dsl/engine/executor/`, `noetl/server/api/core/`, worker dispatch code, replay, cancellation, event-log shape, or PR #603/#604/#605/#606/#607 surfaces.

Validation:

```bash
uv run pytest tests/core/workflow/test_inline_execution.py tests/tools/test_agent_executor.py -q
```

Result: `45 passed, 1 warning` (existing Pydantic deprecation warning).

## Phase D — wiki

- Added wiki page `noetl/core/workflow/playbook/inline_execution.md`.
- Documented Round A scope, decision object shape, eligibility predicates, env flags, `meta.inline_decision`, DEBUG-only logging, and the Round B not-implemented boundary.
- Linked the page from `Home.md` and `_Sidebar.md`.
- Pushed wiki commit `db4900fe3f34fecdaf9062ff5838132758734970` to `noetl/noetl.wiki` master.
- Wiki page: https://github.com/noetl/noetl/wiki/inline_execution

## Phase E — PR

- NoETL commit: `a83f9fc82d690f0eaf0ec10e40bafca1e7414429`.
- Branch pushed: `kadyapam/inline-trivial-children-round-a`.
- Draft PR opened: https://github.com/noetl/noetl/pull/608
- PR is draft and was not merged.

## Issues observed

- `repos/noetl` is left on the feature branch with the unmerged PR commit. I did not stage the `repos/noetl` submodule pointer in ai-meta because the PR is intentionally unmerged.
- `repos/noetl-wiki` was pushed directly to `master`; the ai-meta result commit includes the wiki pointer bump.
- The root `ai-meta` worktree still has the pre-existing `.claude/settings.json` modification; it was not staged.
- No live cluster deploy was run, per the Round A prompt.

## Manual escalation needed

Review draft PR #608. Round B should not start until reviewers approve the detector/dry-run contract and explicitly authorize execution-path work.
