---
thread: 2026-05-26-noetl-inline-trivial-children
round: 2
from: claude
to: codex
created: 2026-05-26T04:30:00Z
status: open
expects_result_at: round-02-result.md
---

# Round A — detector + dry-run observability (no inline execution yet)

> **Predecessor in this thread:**
> `round-01-result.md` (status: `partial`). The Phase B audit found
> the nested-execution path crosses 27 boundaries/allocations and
> touches 7+ files across worker / server / projector / replay /
> wiki. Codex recommended a Round A / Round B split. **Round A is
> detector + dry-run only — no execution-path changes.** The user
> accepted the split. This round implements Round A.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` (Rule 1b — wiki rides with the
pointer bump).

Re-read `round-01-result.md` (in this same thread directory). Its
**audit table** and **Phase B design decisions** are approved as-is.
Do not re-litigate the detection shape, event-log shape, eligibility
rules, or recursion limits.

## What Round A delivers

A foundation that makes the inline path **decidable but not yet
exercised**:

1. New module `noetl/core/workflow/playbook/inline_execution.py`
   with:
   - **Eligibility detector** that takes a child playbook + parent
     context and returns an explicit decision object.
   - **Decision object** carrying:
     - `inline: bool` — would this child be inlined?
     - `reasons: list[str]` — per-rule outcomes (eligibility AND
       safety predicates AND depth check). Always populated; both
     for `inline=True` and `inline=False` cases so logs explain
     "why".
     - `depth: int` — current inline depth.
     - `mode: "metadata_opt_in" | "allow_list" | None`.
   - **Predicates** matching the design table in
     `round-01-result.md` exactly (max_steps=3, max_depth=3,
     `framework: noetl`, allowed `tool.kind in {python, mcp, noop}`,
     no callbacks/async/cursor/parallel/finalizers, no
     `tool.kind: agent`, same tenant, etc).
   - **Allow-list** defaults to paths under
     `automation/agents/mcp/*`. Override via env var
     `NOETL_INLINE_TRIVIAL_CHILDREN_ALLOW_LIST` (CSV).
   - **Metadata opt-in** key: child playbook's
     `metadata.inline_when_safe: true`. Accept boolean true only;
     reject any other value (don't silently accept truthy
     non-bool).

2. Unit tests in `tests/core/workflow/test_inline_execution.py`
   covering:
   - Each individual predicate (one test per "no" reason).
   - Allow-list hit (path under `automation/agents/mcp/*`).
   - Metadata opt-in hit (boolean true), and rejection of
     truthy-but-non-bool values.
   - Depth limit enforcement.
   - Step count limit enforcement.
   - Disallowed tool kinds (notably `tool.kind: agent` blocks
     inlining to avoid transitive recursion in Round A).

3. **Dry-run wiring** in the NoETL agent path
   (`noetl/tools/agent/executor.py`):
   - Behind env flag `NOETL_INLINE_TRIVIAL_CHILDREN=dry_run`.
     Three values: `dry_run` (compute decision + observe + always
     dispatch), `off` (default; skip decision entirely), `enforce`
     (reserved for Round B; for now must error if set so it's not
     silently a no-op).
   - When `dry_run`: call the detector, attach the decision object
     to the parent agent result's `meta.inline_decision`. **Do
     not** change the actual dispatch path — every child still
     goes through `/api/execute` exactly as today.
   - Log line at DEBUG level for each decision (NOT INFO — per
     `agents/rules/logging.md` we keep observability paths off
     the hot log surface).

4. **Wiki update** per Rule 1b — extend a relevant page in
   `repos/noetl-wiki` documenting:
   - The planned inline contract (link the round-01-result.md
     design section indirectly via cross-references; the wiki
     is the contract, not the result file).
   - The dry-run flag and what it observes.
   - The eligibility rules.
   - Explicit "Round A is dry-run only" caveat so an operator
     reading the wiki doesn't think inlining is enforced today.
   - Suggested wiki page: `noetl/core/workflow/playbook/inline_execution.md`
     (new). Surface from `Home.md` and `_Sidebar.md`.

5. **One draft PR on `noetl/noetl`** (do not merge).

6. **Result file** at
   `handoffs/active/2026-05-26-noetl-inline-trivial-children/round-02-result.md`.

## What Round A explicitly does NOT do

- Does NOT change the dispatch path. Every child playbook still
  goes through `/api/execute` and NATS as today.
- Does NOT touch `noetl/core/dsl/engine/executor/lifecycle.py`,
  `noetl/server/api/core/execution.py`, `events.py`, `batch.py`,
  or `noetl/worker/nats_worker.py`'s dispatch/event-emission code.
- Does NOT change event-log shape, replay semantics, cancellation
  behavior, or recursion handling beyond logging.
- Does NOT touch PR #603 / PR #604 / PR #605 / PR #606 / PR #607
  surfaces.
- Does NOT run a live cluster deploy. Round A is a code + tests +
  wiki round; live validation happens in Round B.

If during implementation any of the above feels necessary, stop
and write the result with `status: blocked`. Do not widen the
patch.

## Phases

### Phase A — sync

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   git -C repos/noetl-wiki fetch origin && git -C repos/noetl-wiki checkout master && git -C repos/noetl-wiki pull --ff-only origin master
   ```
   `repos/noetl` should include v2.100.10 (`019a9457`) — PR #607
   has merged.

2. Re-read `round-01-result.md` once more. Cross-check that
   nothing in main has shifted under the assumptions of its
   audit (the audit table cites file:lines; if any of those
   line numbers have drifted by >30 lines, surface it but do
   not let it block).

### Phase B — implement the detector module

3. Branch `repos/noetl`:
   ```
   git -C repos/noetl checkout -b kadyapam/inline-trivial-children-round-a
   ```

4. Add `noetl/core/workflow/playbook/inline_execution.py`
   implementing items 1.* above. Keep the module pure (no DB
   access, no HTTP) — the caller passes in the child playbook
   dict + parent context. Pure makes it easy to unit-test.

5. Add unit tests in
   `tests/core/workflow/test_inline_execution.py` per item 2.
   At least 12 tests; one per predicate plus combinations.

6. Run the focused test suite and confirm green.

### Phase C — wire the dry-run path

7. In `noetl/tools/agent/executor.py`, locate where the NoETL
   framework branch dispatches the nested playbook (audit
   table line `_invoke_noetl_playbook` /
   `execute_playbook_task`). Add the detector call **without**
   replacing the dispatch.

8. Read the env flag once at module load (or via a cached
   helper to support test overrides). Three values:
   - `off` (default): skip detector entirely. Zero overhead.
   - `dry_run`: call detector, attach decision to result
     meta, log at DEBUG.
   - `enforce`: **raise / log + error**. Reserved for Round B;
     deny it explicitly so a future operator doesn't think
     Round A is doing the inlining.

9. The decision object goes into the parent agent result
   under `meta.inline_decision` so it's observable via the
   agent envelope shape that PR #603/#604/#605/#607 already
   touched.

10. Update tests in `tests/tools/agent/` (or wherever the agent
    executor tests live) to cover:
    - `off` flag: no detector call, no `meta.inline_decision`
      on the result.
    - `dry_run` flag: detector called, `meta.inline_decision`
      present with the expected shape, **dispatch still runs**
      (mock the HTTP call to assert it fires).
    - `enforce` flag: errors clearly with "Round B not yet
      implemented" message.

### Phase D — wiki update (mandatory per Rule 1b)

11. Add a new wiki page
    `repos/noetl-wiki/noetl/core/workflow/playbook/inline_execution.md`
    documenting:
    - The Round A scope: detector + dry-run + observability only.
    - The decision object shape.
    - The eligibility predicates with reasons.
    - The env flag and its three values.
    - Where to find the decision in the agent result
      (`meta.inline_decision`).
    - **An explicit "Round B not yet implemented" callout** so
      operators don't think inlining is active.
    - Cross-link to the round-01-result.md design and the
      ephemeral_blueprints architecture doc.

12. Surface the new page from `Home.md` (or the relevant index
    page) and `_Sidebar.md`.

13. Commit + push the wiki to `master`:
    ```
    git -C repos/noetl-wiki add -A
    git -C repos/noetl-wiki commit -m "wiki(inline_execution): document Round A detector + dry-run contract"
    git -C repos/noetl-wiki push origin master
    ```

### Phase E — open draft PR + write result

14. Commit + push the noetl branch:
    ```
    git -C repos/noetl add -A
    git -C repos/noetl commit -m "feat(inline-execution): Round A detector + dry-run observability (no execution change)"
    git -C repos/noetl push -u origin kadyapam/inline-trivial-children-round-a
    ```
15. Open draft PR with `gh pr create --repo noetl/noetl`. Body
    covers the Round A scope, the eligibility predicates, the
    env-flag semantics, the wiki link, and **explicit
    callouts** for what does NOT change yet (dispatch path,
    event log, replay).

16. Write
    `handoffs/active/2026-05-26-noetl-inline-trivial-children/round-02-result.md`.
    Required sections:
    ```
    ## Phase A — sync
    ## Phase B — detector module
    ## Phase C — dry-run wiring
    ## Phase D — wiki
    ## Phase E — PR
    ## Issues observed
    ## Manual escalation needed
    ```

17. Commit + push the result file.

## Hard rules

- **Do not merge the PR.** Open as draft, link, stop.
- **Do not change dispatch behavior.** Every child still goes
  through `/api/execute` after this round.
- **Do not touch event-log shape / replay / cancellation
  semantics.** Round B territory.
- **Do not log at INFO** for the detector decisions. DEBUG
  only (`agents/rules/logging.md`).
- **`enforce` mode must explicitly error** so it isn't
  silently equivalent to `dry_run`. Round B will implement it.
- **Do not retroactively rewrite event-log rows.** Event log
  is immutable.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set
  action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- **Wiki update is mandatory.** Round A is not complete
  without Phase D.

## What success looks like

- New `noetl/core/workflow/playbook/inline_execution.py` module
  ships with the eligibility detector.
- ≥12 unit tests for the detector predicates pass.
- NoETL agent path optionally consults the detector under
  `NOETL_INLINE_TRIVIAL_CHILDREN=dry_run`. Dispatch behavior
  unchanged.
- The parent agent envelope carries `meta.inline_decision` when
  the flag is `dry_run`.
- `enforce` flag errors clearly.
- noetl-wiki documents the contract + the dry-run-only caveat.
- Draft PR open on `noetl/noetl`.
- Result file written and pushed.

## Out of scope (Round B and beyond)

- The actual inline execution path (Round B).
- Live cluster validation of inlining behavior (Round B).
- `combine command.completed + step.exit + call.done into one
  boundary event` (separate handoff candidate; not opened yet).
- Any changes to `noetl/core/dsl/engine/executor/`,
  `noetl/server/api/core/execution.py`, `events.py`,
  `batch.py`, `noetl/worker/nats_worker.py` dispatch code.
- Replay/projector/listings consumer changes.
