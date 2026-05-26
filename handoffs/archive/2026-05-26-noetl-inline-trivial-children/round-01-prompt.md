---
thread: 2026-05-26-noetl-inline-trivial-children
round: 1
from: claude
to: codex
created: 2026-05-26T03:50:00Z
status: open
expects_result_at: round-01-result.md
---

# Inline trivial nested playbook execution

> **Predecessors (context):**
> - `handoffs/archive/2026-05-24-travel-itinerary-planner-consolidation/round-01-result.md`
>   — itinerary-planner consolidation hit ~10s per turn (target <2s). Per-step
>   platform overhead is ~100–600ms, and most of an itinerary turn is a chain
>   of `tool: agent` calls into nested mcp/firestore playbooks.
> - `noetl/noetl#607` (open as of this round) — collapses the case-action
>   emit branch from 4 sequential HTTP roundtrips into one batched call,
>   the small-win sibling to this work.
> - `handoffs/archive/2026-05-26-noetl-credential-refs-round-b/round-01-result.md`
>   — Round B established the `producer_scrub_payload` pattern at the
>   worker result boundary; relevant because inlined children share that
>   boundary.
> - Architecture principle:
>   `repos/docs/docs/architecture/ephemeral_blueprints.md` — playbooks are
>   ephemeral blueprints. Today every nested-playbook invocation is a
>   separate execution_id traversal of the full distributed runtime. The
>   trivial-children case never benefits from that distribution.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`,
`agents/rules/safety.md`,
`agents/rules/execution-model.md`,
`agents/rules/writing-style.md` (no "canonical" in prose), and
`agents/rules/wiki-maintenance.md` (Rule 1b — wiki rides with
the pointer bump).

## Why this round exists

The travel itinerary-planner workflow is dominated by `tool: agent`
calls into `automation/agents/mcp/firestore` (each step writes one
event, sets one doc, etc.). Even with batched event emission and
the consolidated playbook from PR #604/#605/#606/#607, a turn lands
at ~8–15s on the live cluster — far from the <2s target the
ephemeral-blueprints architecture envisions for typical agent
turns.

The remaining cost is **per-nested-execution overhead**: every
`tool: agent framework: noetl` step:

1. Worker HTTPs to noetl-server `/api/execute` with the child path
   + workload.
2. Server allocates a new `execution_id`, writes
   `playbook.initialized` and `workflow.initialized` events, then
   publishes the first command for the child via NATS.
3. Some worker (often the same pod that issued the request) pulls
   the child's first command from NATS, claims it in Postgres, runs
   it, emits ~7 events per step.
4. Repeats per child step. Child's `playbook.completed` event is
   written.
5. The parent worker step that fired the `tool: agent` call resumes
   and reads the child's result.

For a child playbook with 1–3 trivial steps (`mcp/firestore.append_event`,
`mcp/firestore.set_doc`, etc.), this overhead is **500–1500ms per
nested call**. For 8–12 nested calls per parent turn that is
5–12s of pure platform overhead. Inlining trivial children — running
them in-process inside the parent's worker, skipping NATS and the
new-execution allocation — is the architectural fix.

The fix is non-trivial because it changes how nested executions
appear in the event log, replay semantics, and cancellation. This
round is **audit-first** with an explicit escape valve: if the
implementation surface is too wide, codex writes a design report
and stops at Phase B.

## What this round delivers

The end-state across one or more rounds:

1. A way to recognize **trivial children** that are safe to inline.
2. A code path in the worker that invokes a trivial child in-process
   instead of issuing the HTTP/NATS hop.
3. An event-log representation for inlined execution that preserves
   replay semantics. The most likely shape: keep the child
   `execution_id`, write all child events in-band with parent step
   correlation, mark the execution as `inlined_in: <parent_execution_id>`.
4. Replay parity: replaying the parent execution still reconstructs
   the child's effects in the same order.
5. Cancellation: cancelling the parent cancels any in-flight inlined
   child. (Same process — easier than the distributed case.)
6. Recursion safety: inlined children that themselves use `tool: agent`
   either (a) recurse into inline within a depth limit, or (b) fall
   back to the dispatched path.
7. Concurrency: inlined children consume the parent's inflight slot;
   that is, an inlined call inside one of the parent worker's
   max_inflight=6 slots does not free that slot.
8. Tests proving:
   - A representative trivial-child step (mcp/firestore.append_event)
     runs inline and produces the same events as the dispatched path.
   - Non-trivial children still dispatch.
   - Recursion limit enforced.
   - Cancellation propagates.
9. Live cluster validation: re-run the consolidated itinerary-planner
   turn measured at ~10s in the predecessor round; demonstrate the
   per-turn duration with inlining.
10. Wiki update per Rule 1b — extend the relevant noetl-wiki pages
    (`worker.md`, `runtime_events.md`, or a new
    `inline_execution.md`) documenting the inlining contract.

## Hard escape valve

This is a multi-round candidate. **If the Phase B audit reveals the
implementation surface is too wide for one safe code change**, write
the design report as the round-01 result with `status: partial` and
stop before Phase C. The user opens the next round with the agreed
design, just like the storage-side credential hygiene work did when
codex split it into Round A + Round B.

## Phases

### Phase A — sync

1. Sync `repos/noetl`, `repos/noetl-wiki`, `repos/ops`,
   `repos/travel`. Confirm noetl main includes PR #607 (the
   case-action batching). If it does not, the rest of the round
   still proceeds; just note it.

### Phase B — audit + design decisions

2. Branch `repos/noetl`:
   ```
   git -C repos/noetl checkout -b kadyapam/inline-trivial-children
   ```

3. **Audit the nested-execution path end-to-end.** Trace exactly
   what happens today when a worker step has
   `tool: kind: agent, framework: noetl, entrypoint: <path>`. The
   key files (based on the round-01 audit of the storage-side
   thread):

   - `noetl/core/workflow/playbook/executor.py` — the parent-side
     dispatch (HTTP POST to `/api/execute`).
   - `noetl/server/api/core/execution.py` — the `/api/execute`
     handler that allocates execution_id + publishes the first
     command.
   - `noetl/core/dsl/engine/executor/lifecycle.py` — initial event
     writes for a new execution.
   - `noetl/worker/nats_worker.py` — child-side command pickup +
     run.

   Produce the audit in the result file: every line where a
   nested-playbook traversal crosses a process boundary or
   allocates a new resource (execution_id, NATS subject, DB
   transaction).

4. **Decide trivial-child detection.** Two viable shapes:
   - **(i) Heuristic:** automatically inline children that satisfy
     `step_count <= N AND no callback_subject AND no recursive
     tool: agent AND no spec.async`. The detector reads the child
     playbook from the catalog before dispatch. N is a tuning
     parameter (suggest 3 or 5 initially).
   - **(ii) Explicit opt-in:** the child playbook declares
     `spec.inline_when_safe: true` (or similar). The dispatcher
     inlines only when the child requests it AND the runtime
     safety predicates hold (depth limit, no callback subject,
     same tenant, etc.).
   - **(iii) Hybrid:** explicit opt-in + automatic detection for
     known-safe MCP playbooks under `automation/agents/mcp/*`
     (firestore, postgres, etc).

   Recommend **(iii)** in the design but pick whichever surface
   minimizes implementation churn. Document the choice.

5. **Decide event-log shape for inlined execution.** Two viable
   shapes:
   - **(a) Preserve child execution_id.** The child still gets its
     own `execution_id`, the event log carries all the child's
     events under that id, with each event annotated
     `meta.inlined_in_parent: <parent_execution_id>` and
     `meta.inlined_in_command: <parent_command_id>`. Replay walks
     the child's events as usual. Easiest backward-compat with
     replay tooling.
   - **(b) Absorb into parent.** The child's effects appear as
     events on the parent execution_id with the parent's
     command_id. Smallest event-log growth but rewrites how
     consumers (status endpoint, listings, replay) reason about
     execution boundaries.

   Recommend **(a)** in the design. Replay tooling, the listings
   endpoint, the `playbook.completed` waiters, and the projector
   should not have to know about inlining.

6. **Decide recursion + safety predicates.** Document:
   - depth limit (suggest 3 or 4)
   - what disables inlining at runtime (`spec.callback_subject`,
     `tool: kind: agent` with non-`framework: noetl`, any
     long-running tool, any output_ref that requires NATS routing)
   - cancellation propagation pattern (cancel cascades from parent
     to in-flight inlined children via cooperative checks)
   - failure propagation (child failure = parent step failure, same
     as today; no change here)

7. **Audit risks.** What breaks if the design is wrong:
   - Replay parity: events emitted in the inlined path must be
     byte-identical to the dispatched path (modulo timestamps).
   - Worker `max_inflight` accounting: an inlined child must not
     double-count against the parent's inflight slot.
   - The Round A storage-side credential hygiene (`$noetl_ref` +
     deferred templates) — inlined children share the parent
     worker process and the parent's resolved credential
     namespace. The scrub at worker result boundary still applies
     because the inlined child's result is consumed by the same
     scrub site.
   - The producer-side scrub from Round B (`producer_scrub_payload`)
     applies to inlined writes the same way it does dispatched
     ones — same code paths.

8. **Write a design section in the result** that captures choices
   (i/ii/iii, a/b, depth limit, etc.) with rationale. If at this
   point the implementation surface looks too wide for one round
   (e.g. requires changes in 6+ files across worker/server/projector/
   replay), **stop here** and write the result with
   `status: partial`. The user opens round-02 with the agreed
   design.

### Phase C — implementation (gated)

> ***Run only after explicit human go-ahead. Wait phrase: `proceed with inline implementation`.***

9. Implement the new code path:
   - Add an `inline_executor` (or whatever name) in
     `noetl/core/workflow/playbook/executor.py` that runs a trivial
     child in-process. Reuses the existing event-write helpers,
     keychain resolver, result scrub.
   - The dispatcher decides at runtime whether to invoke
     `inline_executor.run(child_path, workload, parent_event)` or
     fall through to the HTTP/NATS dispatch.
   - Event emission stays through the existing batched paths so
     the read side sees the same shape.

10. Tests per item 8 in the result section. Cover the typical
    `mcp/firestore` shape.

### Phase D — live validation (gated by C)

11. Pre-authorized when Phase C lands: build the image, helm
    upgrade `--reuse-values --set image.tag=<tag>`, register a
    temporary copy of the itinerary-planner playbook, run 3–5 turns
    with placeholder-safe inputs. Capture per-turn duration. Target
    is "noticeably faster than the consolidated baseline" (which
    was 8.846s / 12.494s / 15.213s); a 2–4× improvement would be a
    strong result.

12. Cross-check: replay the inlined execution from the event log
    and confirm replay parity (same final state).

### Phase E — wiki + PR

13. Wiki update per Rule 1b. Likely targets:
    - `noetl/server/api/execution.md` or a new
      `noetl/core/workflow/playbook/inline_execution.md`.
    - Document the inline-trivial-children contract: detection
      rules, event-log shape, cancellation, replay parity,
      developer-facing notes for playbook authors.
14. Open draft PR on `noetl/noetl`. PR body covers everything in
    sections (audit, design, implementation, tests, live results,
    wiki).
15. Write the result file with the full report.

## Hard rules

- **Do not merge the PR.**
- **Do not retroactively rewrite event-log rows.** Event log is
  immutable.
- **Do not weaken the read-side redaction (PR #603) or
  producer-side scrub (PR #605).** Inlined children share the
  same scrub sites; verify.
- **Do not break replay parity.** Replaying an execution that
  contains inlined children must produce the same final state as
  one that ran with full dispatch.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- **Phase C is gated** behind the wait phrase
  `proceed with inline implementation`. If you reach Phase C and
  the user hasn't said it, write the result at Phase B with
  `status: partial`.
- **Wiki update is mandatory if Phase C runs.** No PR without the
  wiki update.
- **If Phase B reveals the surface is wider than one safe round**,
  stop, write the design as the round-01 result with
  `status: partial`, and explicitly recommend a Round A / Round B
  split per the storage-side hygiene precedent.

## What success looks like (full round)

- Trivial mcp/firestore-style children run in-process; non-trivial
  children still dispatch via HTTP/NATS.
- Per-turn duration of the consolidated itinerary-planner drops
  by ≥2× on the live cluster (target ≥3×).
- Replay of an inlined execution reproduces the same state as the
  dispatched form.
- Event log carries child events under the child's `execution_id`
  with parent correlation metadata.
- noetl-wiki documents the inlining contract.
- Draft PR open on `noetl/noetl`.
- Result file written and pushed.

## Out of scope (separate handoffs)

- Combining `command.completed` + `step.exit` + `call.done` into a
  single boundary event (codex-sized; touches event-log consumers
  across the codebase + replay; tracked separately).
- Worker max_inflight tuning.
- Server-side projection updater (the noetl.execution projection
  lag that PR #606 worked around via LATERAL join).
- KEDA / Helm / GKE infra changes.
