---
thread: 2026-05-26-noetl-inline-trivial-children
round: 3
from: claude
to: codex
created: 2026-05-26T06:36:39Z
status: open
expects_result_at: round-03-result.md
wait_phrase: "proceed with inline implementation"
---

# Round B — inline runner (actually skip /api/execute + NATS for safe children)

> **Predecessors in this thread:**
> `round-01-result.md` (Phase B audit + Round A/B split design — approved).
> `round-02-result.md` (Round A detector + dry-run wiring shipped as PR #608).
> `round-02-result.md` was followed by three pure follow-up PRs landing
> Round A's live-cluster verification:
> - **PR #609** (`6b0571aa`, `fix(worker): preserve meta.inline_decision
>   through control-context projection`) added an `_extract_control_context`
>   carve-out in `noetl/worker/nats_worker.py` so the decision dict survives
>   the nested-scalars-only projection rule and reaches the event log.
> - **PR #610** (`2056f988`, `fix(inline-execution): detector falls back to
>   catalog when child is placeholder`) added an HTTP catalog fallback in
>   `executor.py` because the worker's local filesystem never holds
>   cross-repo entrypoints like `automation/agents/mcp/firestore` —
>   without it every dry-run decision blamed `missing_tool_kind` on the
>   2-step placeholder stub.
> - **PR #611** (`244338dd`, `perf(inline-execution): cache catalog lookups
>   in dry-run loader`) added a process-local cache with negative caching
>   (TTL via `NOETL_INLINE_TRIVIAL_CHILDREN_CATALOG_CACHE_TTL_SECONDS`,
>   default 300s). Live per-turn latency: 39s uncached → 7s cold / 4s
>   warm.
>
> Live cluster state confirms Round A is production-stable on GKE: helm
> rev 165, image `inline-cache-20260526062141`, noetl HEAD `38d14a6e`,
> `NOETL_INLINE_TRIVIAL_CHILDREN=dry_run` env var set on noetl-worker.
> Every parent `kind: agent` step that targets a child under
> `automation/agents/mcp/*` produces `meta.inline_decision` with the
> right signal in the event log.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose),
`agents/rules/logging.md` (no INFO logs on the hot path; DEBUG with
rate-limiting for high-frequency observability),
`agents/rules/wiki-maintenance.md` (Rule 1b — wiki rides with the
pointer bump).

Re-read `round-01-result.md` end to end. Its **Phase B Round B
recommended sequence** (lines 156–164) and the **Event-log shape**,
**Cancellation and failure**, and **Replay and scrub invariants**
sections are approved as the design contract. Do not re-litigate
those decisions. If a load-bearing assumption has to change to make
the implementation work, **stop and write `status: blocked`** —
write a follow-up prompt rather than widening the patch.

## What Round B delivers

A worker-side inline runner that actually skips the `/api/execute`
HTTP round-trip and the NATS-dispatch round-trip for children the
Round A detector approves, while preserving:

- Child `execution_id` allocation and lifecycle event order.
- Command-row projection parity (replay, status, listings keep
  working).
- Cancellation propagation (parent cancel → child cooperatively
  aborts).
- Result scrub and `$noetl_ref` storage-side externalization
  (PR #603 / #604 / #605 / #606 / #607 stay intact).
- The detector's `meta.inline_decision` envelope shape from
  Round A. When inline execution runs, ALSO append
  `meta.inlined_in_parent`, `meta.inlined_in_command`,
  `meta.inline_depth`, `meta.inline_mode = "worker"` per Phase B
  design (`round-01-result.md` lines 106–117).

The `enforce` value of `NOETL_INLINE_TRIVIAL_CHILDREN` flips from
the Round A "configuration error" to "actually run inline when the
detector says yes". `dry_run` keeps Round A semantics unchanged
(observe + always dispatch via HTTP+NATS). `off` stays the default
zero-overhead path.

## Constraints (load-bearing — do not relax without a new round)

1. **Detector is the gate.** Round B never inlines a child the
   detector blocked. The detector lives in
   `noetl/core/workflow/playbook/inline_execution.py` and is
   final — do not bypass it, do not add a second decision site.
2. **Child `execution_id` is preserved.** Allocate a fresh
   snowflake exactly like `/api/execute` does today. Use the
   engine lifecycle helper, not a hand-rolled `id()`.
3. **Use existing event/projection helpers**, not direct table
   writes. The places `/api/execute` and the worker batch-emit
   path call into engine lifecycle + event batch + outbox
   helpers are the right entry points. If a helper is too
   coupled to NATS to reuse, factor a thin seam — do not
   duplicate the helper.
4. **Command projection rows still get written.** Even though
   NATS publish is skipped, the `noetl.command` rows must exist
   so replay, status, listings, and cancellation queries don't
   diverge from the dispatched path.
5. **Event-log immutability stays intact.** No rewrite of past
   rows. Inline metadata is added on the new rows that the
   inline runner produces, not patched onto rows the dispatched
   path produced earlier.
6. **Cancellation cooperatively checks the parent.** Before
   each child step, the inline runner consults the parent's
   cancellation state. If the parent is cancelled, the child
   appends `execution.cancelled` and returns an agent envelope
   with `status: "error"`, `error.code: "PLAYBOOK_CANCELLED"`.
7. **Recursion-depth guard.** `meta.inline_depth` is bounded by
   the detector's `DEFAULT_MAX_DEPTH` (`3`). A nested inline
   request beyond that depth must hit the dispatched path,
   not silently fail.
8. **Logging.** All inline-runner step boundaries log at DEBUG.
   No INFO on per-step or per-call paths. Per
   `agents/rules/logging.md`.
9. **No "canonical"** in any code comment, commit message, PR
   body, doc, or wiki page. Per
   `agents/rules/writing-style.md`.
10. **No live deploy yet.** Phase D's live verification is gated
    on the wait phrase `proceed with inline implementation`.

## Phases

### Phase A — sync + branch

1. Sync:
   ```
   git -C repos/noetl fetch origin && git -C repos/noetl checkout main && git -C repos/noetl pull --ff-only origin main
   git -C repos/noetl-wiki fetch origin && git -C repos/noetl-wiki checkout master && git -C repos/noetl-wiki pull --ff-only origin master
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only origin main
   ```
   `repos/noetl` HEAD should be at `38d14a6e` (PR #611 merge) or a
   newer commit on `main`. If a newer release commit has landed,
   note it but do not block on it.

2. Re-read `round-01-result.md` (sections **Event-log shape**,
   **Cancellation and failure**, **Replay and scrub invariants**,
   **Recommended round split**) and `round-02-result.md`
   end to end.

3. Branch:
   ```
   git -C repos/noetl checkout -b kadyapam/inline-trivial-children-round-b
   ```

### Phase B — implement the inline runner

4. Add the runner under
   `noetl/core/workflow/playbook/inline_runner.py` (new file,
   sibling to `inline_execution.py`). Public surface (suggested,
   you may refine):
   ```python
   def run_inline(
       *,
       parent_execution_id: int,
       parent_command_id: int,
       parent_step: str,
       child_playbook: dict,
       child_input: dict,
       inline_decision: InlineDecision,
       jinja_env,
       cancellation_probe,        # callable returning bool
       event_emitter,             # batch event emit handle
       result_handler,            # ResultHandler for scrub+ref
       command_projector,         # writes noetl.command rows
       depth: int,
   ) -> InlineResult: ...
   ```
   `InlineResult` mirrors the agent envelope shape the executor
   already returns (`status`, `data`, `error`, `meta`) so the
   call site in `executor.py` can substitute it 1:1 for the
   HTTP/NATS path.

5. Reuse engine lifecycle helpers for child id allocation +
   initial events. The relevant calls today are in
   `noetl/core/dsl/engine/executor/lifecycle.py` lines 142–214
   (audit table). If those helpers are wrapped behind
   `/api/execute` in a way that can't be called from worker
   process directly, factor an internal entry point — don't
   duplicate the body. Document the seam in a one-paragraph
   header comment on the new function.

6. Each child step runs in-process. The flow per step:
   - Probe parent cancellation. If cancelled, append
     `execution.cancelled` for the child, emit a terminal
     envelope, return.
   - Render the step with the child Jinja env.
   - Execute the tool. Only `python`, `mcp`, `noop` are reachable
     because the detector blocked anything else. The tool calls
     must use the same execution surfaces (e.g. MCP client
     factory, python plugin entry) that the worker's dispatched
     path uses.
   - Scrub + externalize via `ResultHandler.process_result(...,
     scrub_context=...)` — same path Round A's executor.py
     already routes results through.
   - Emit the standard step boundary events (`command.started`,
     `command.completed`, `step.enter`, `step.exit`, etc) via
     the same batch helper used by `nats_worker.py` lines
     1929–1960 and 2340–2356. Add the inline metadata
     (`meta.inlined_in_parent`, `meta.inlined_in_command`,
     `meta.inline_depth`, `meta.inline_mode = "worker"`) on
     every event the inline runner emits.
   - Write the matching `noetl.command` projection rows.

7. After the last step, write the child's terminal lifecycle
   (`workflow.completed` / `playbook.completed` or the failure
   equivalents) using engine event helpers
   (`noetl/core/dsl/engine/executor/events.py` lines 2141–2413).
   Result envelope must match the dispatched path bit-for-bit
   (excluding `meta.inlined_*` keys).

### Phase C — wire into the agent executor

8. In `noetl/tools/agent/executor.py`, update the NoETL
   framework branch to consult
   `_inline_decision_for_noetl_child` exactly as today, but:
   - If `mode == "off"`: unchanged (zero overhead).
   - If `mode == "dry_run"`: unchanged from Round A — call
     detector, log + attach `meta.inline_decision`, then run
     the existing HTTP/NATS dispatch.
   - If `mode == "enforce"` AND `inline_decision.inline is True`:
     **run the inline runner instead of `_invoke_noetl_playbook`**.
     Attach the same `meta.inline_decision` plus the
     `meta.inlined_*` set the runner emitted onto the child's
     terminal events. Return the runner's envelope.
   - If `mode == "enforce"` AND `inline_decision.inline is False`:
     fall back to the dispatched path. Do NOT error. The detector
     intentionally declines unsafe children; that's the safety
     net.

9. Replace the `INLINE_TRIVIAL_CHILDREN_UNAVAILABLE` error path
   from Round A with the above. Update the comment on
   `_inline_decision_for_noetl_child` to note Round B is now
   wired.

10. Add tests in `tests/tools/test_agent_executor.py` covering:
    - `enforce` + detector says inline: runner is called, no
      HTTP POST to `/api/execute`, envelope shape matches.
    - `enforce` + detector says no-inline: HTTP dispatch runs
      (mocked), runner NOT called.
    - `enforce` + runner raises: error envelope with
      `kind: "agent.runtime"`, `code: "INLINE_RUNNER_FAILED"`,
      and the runner exception text masked through scrub. No
      dispatch fallback (an inline failure is a real failure).
    - `dry_run` + detector says inline: runner NOT called,
      dispatch DOES run, `meta.inline_decision` present.
    - Nested-inline blocked at depth 3: outer two inline, third
      falls back to dispatch.

11. Add tests in `tests/core/workflow/test_inline_runner.py`
    covering at minimum:
    - Single-step `python` child: terminal envelope matches
      dispatched fixture (excluding inline meta).
    - Single-step `mcp` child: same as above.
    - Parent cancellation mid-child: `execution.cancelled`
      emitted, envelope has `error.code: PLAYBOOK_CANCELLED`.
    - Child step failure: terminal envelope status `error`,
      events match dispatched fixture.
    - Recursion depth = 3 then 4: at depth 3 inline runs; at
      depth 4 the detector blocks and the executor falls back
      to dispatch.
    - `noetl.command` projection rows exist for inline child
      with the right `inline_mode` metadata.

12. Add a parity test in
    `tests/core/workflow/test_inline_runner_parity.py` (new
    file) that runs the same `automation/agents/mcp/firestore`
    style fixture child twice — once dispatched (mock HTTP+NATS),
    once inline — and diffs the resulting event sequences. The
    diff must only show: timestamps, event ids, command ids
    (one path allocates fewer), and the `meta.inlined_*` keys.
    Everything else must match.

### Phase D — live validation (GATED)

> ***Run only after explicit human go-ahead. Wait phrase: `proceed with inline implementation`.***

13. Build a temp image off the round-B branch and roll it onto
    the GKE cluster via the noetl/ops automation. Set the
    worker env var `NOETL_INLINE_TRIVIAL_CHILDREN=enforce`.
    Leave the dry-run cache TTL env var at its default.

14. Run 5 itinerary-planner turns end-to-end. Pull the
    `result.context.meta.inline_decision` + `meta.inlined_*`
    rows for `automation/agents/mcp/firestore` events from
    the executions API. Record per-turn latency vs.
    Round A `dry_run` baseline (Round A cold-cache: 7s,
    warm-cache: 4s).

15. Spot-check a parent cancel during a turn that has an
    inline child in flight. Confirm `execution.cancelled`
    appears for the child and the parent step terminates
    with the right error envelope.

16. If any anomaly, **stop the live arc**, flip
    `NOETL_INLINE_TRIVIAL_CHILDREN` back to `dry_run`,
    write the result file with `status: partial`, and
    surface the anomaly. Do NOT keep iterating live.

### Phase E — wiki + draft PR

17. Update wiki page
    `repos/noetl-wiki/noetl/core/workflow/playbook/inline_execution.md`
    with a new "Round B — worker inline execution" section.
    Document:
    - The runner's public surface.
    - The added `meta.inlined_*` keys and their semantics.
    - The cancellation contract.
    - The recursion-depth boundary and the dispatch fallback.
    - The `enforce` mode's new behavior (no longer an error).
    - The dispatched-vs-inline parity contract.
    - The Round A → Round B operational migration
      (`enforce` is now the production target; `dry_run` stays
      available for staged rollouts).
    Cross-link to `round-03-result.md` and the
    `ephemeral_blueprints` architecture doc.

18. Also add a wiki page (new) at
    `repos/noetl-wiki/noetl/core/workflow/playbook/inline_runner.md`
    documenting the runner module specifically.

19. Surface both pages from `Home.md` and `_Sidebar.md`.

20. Commit + push wiki to `master`:
    ```
    git -C repos/noetl-wiki add -A
    git -C repos/noetl-wiki commit -m "wiki(inline_runner): document Round B inline execution contract"
    git -C repos/noetl-wiki push origin master
    ```

21. Commit + push the noetl branch:
    ```
    git -C repos/noetl add -A
    git -C repos/noetl commit -m "feat(inline-execution): Round B worker inline runner (enforce mode wired)"
    git -C repos/noetl push -u origin kadyapam/inline-trivial-children-round-b
    ```

22. Open draft PR with `gh pr create --repo noetl/noetl`. Body:
    - Round B scope.
    - Constraint table from this prompt.
    - Test matrix (Phase B + C tests + parity test).
    - Phase D evidence (or "Phase D blocked: awaiting wait
      phrase" if you stopped at Phase C).
    - Wiki link.
    - Explicit callout: replay parity, event-log immutability,
      cancellation contract, and the
      gateway/worker boundary discipline from
      `agents/rules/execution-model.md` are preserved.

23. Write
    `handoffs/active/2026-05-26-noetl-inline-trivial-children/round-03-result.md`.
    Required sections:
    ```
    ## Phase A — sync + branch
    ## Phase B — inline runner
    ## Phase C — agent executor wiring
    ## Phase D — live validation
    ## Phase E — wiki + PR
    ## Issues observed
    ## Manual escalation needed
    ```

24. Commit + push the result file.

## Hard rules

- **Do not merge the PR.** Draft + link only.
- **Do not push to `main`.** No force-pushes anywhere.
- **Do not touch the event-log shape on rows already produced.**
  Inline metadata lives on the new rows the runner emits.
- **Do not bypass the detector.** Inline execution gates on
  `inline_decision.inline is True` regardless of `enforce`.
- **Do not log at INFO** for per-step inline boundaries.
  DEBUG only.
- **Do not store secrets** in any file under ai-meta (repo is
  public).
- **Do not run Phase D** until the human says
  `proceed with inline implementation`. If a previous round
  already received that phrase verbally, the executor must
  still see it under THIS round to act on Phase D.
- **Do not change PR #603 / PR #604 / PR #605 / PR #606 /
  PR #607 / PR #608 / PR #609 / PR #610 / PR #611 surfaces.**
- **No "canonical"** in any prose or code.
- **Preserve the gateway/worker boundary.** Inline execution
  moves work INTO the worker that's already running the parent
  step; it must not move work into the gateway, into the
  client, or onto a new persistent process.

## What success looks like

- New `noetl/core/workflow/playbook/inline_runner.py` lands
  with a clean public surface.
- The agent executor's `enforce` mode runs inline when the
  detector approves, dispatches otherwise.
- Tests:
  - Detector unit tests from Round A still pass.
  - Inline runner tests (≥ the matrix in step 11) pass.
  - Parity test (step 12) green.
  - Agent executor tests (step 10) green.
- Wiki documents the Round B contract under the new section
  + the new runner page.
- Draft PR open on `noetl/noetl`.
- If Phase D was unlocked: live cluster runs 5 turns clean,
  cancel cascade works, latency numbers recorded vs. Round A
  baseline.
- Result file written and pushed.

## Out of scope (future work)

- Combine `command.completed + step.exit + call.done` into a
  single boundary event (separate handoff candidate).
- Inline support for `tool.kind: agent` (transitive inline).
  Round B keeps `agent` blocked at the detector.
- Inline support for callback / async / cursor / parallel /
  distributed loops.
- Cross-tenant / cross-org inline.
- Helm/Ops manifest changes to default
  `NOETL_INLINE_TRIVIAL_CHILDREN=enforce` cluster-wide. That
  rollout step is operator policy and lives in a separate
  noetl/ops PR.

## FINAL REPORT shape

`round-03-result.md` frontmatter:

```yaml
---
thread: 2026-05-26-noetl-inline-trivial-children
round: 3
from: codex
to: claude
created: <ISO8601 UTC>
in_reply_to: round-03-prompt.md
status: complete | partial | blocked
---
```

Body sections in this exact order:

```markdown
## Phase A — sync + branch
- ...

## Phase B — inline runner
- ...

## Phase C — agent executor wiring
- ...

## Phase D — live validation
- (or "Phase D blocked: awaiting `proceed with inline implementation`")

## Phase E — wiki + PR
- ...

## Issues observed
- Grep-able fingerprints only. No paraphrase. Include
  commit SHAs, branch names, PR URLs, real error strings.

## Manual escalation needed
- Anything that couldn't be done unattended, with the
  exact command(s) a human should run.
```
