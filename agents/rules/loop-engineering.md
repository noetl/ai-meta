# Loop Engineering

Any repeatable agent loop — retry, plan-execute-verify, autonomous background
loop, self-correction, CI-fix loop — is coordination state, not throwaway
control flow. The same durability principle that governs
[`memory-workflow.md`](memory-workflow.md) and [`handoffs.md`](handoffs.md)
applies: a loop's goal, bounds, and progress must be recorded somewhere a
future session or agent can read, not held only in a live context window.

## Where loop definitions live

- `loops/active/<slug>/loop.md` — one directory per loop, scaffolded from
  `loops/templates/loop.md`.
- Closed loops move to `loops/archive/<slug>/` with their outcome recorded.
- Use the `loop-new` skill to open one, `loop-close` to close it.

## Every loop declares, before the first iteration runs

1. **Goal** — a concrete, checkable definition of done. Not "improve X,"
   but a condition an agent (or a test) can evaluate to true/false.
2. **Stop conditions** — both:
   - Success: the checkable condition that ends the loop cleanly.
   - Hard bounds: max iterations, max wall-clock time, max cost/token
     budget. A loop without hard bounds is not allowed to start.
3. **Checkpoint cadence** — what gets recorded each iteration (attempt
   summary, diff, test result) and where (the loop file, a memory entry, a
   sync note).
4. **State source** — where the loop resumes from if the session is
   interrupted. Each iteration must be safe to resume or re-run from
   recorded state, not restart from scratch and not double-apply a partial
   effect.
5. **Escalation path** — what happens when hard bounds are hit without
   success: open a tracked issue, open a handoff thread, or stop and tell
   the human. Decide this before the loop runs, not after it fails.

## Loop vs. handoff

A loop is mechanical repetition toward a checkable goal, typically by one
agent, resumable from recorded state. A handoff is a cross-agent or
cross-session brief for work that needs a different tool, a different agent,
or an explicit human gate. When a loop stalls against its hard bounds, or its
next step needs a capability the current agent does not have, escalate by
opening a handoff — see [`handoff-routing.md`](handoff-routing.md) for that
decision — rather than quietly widening the loop's bounds.

## Rules

- Never run a loop without an explicit stop condition and a hard iteration
  or time cap recorded in `loops/active/<slug>/loop.md` first.
- Record each iteration's meaningful outcome as it happens — append, don't
  overwrite — so a later session can tell what was already tried.
- Destructive actions inside a loop iteration (push, deploy, cancel, merge)
  are gated the same way a handoff phase is gated: see
  [`safety.md`](safety.md) and the callback/hook rule in
  [`execution-model.md`](execution-model.md). A loop does not get to skip
  human gates just because it is automated.
- Closing a loop without recording an outcome status (`converged`,
  `stopped-at-bound`, `escalated`) is not allowed; see `loop-close`.
- If a loop escalates, the escalation target (issue or handoff) must be
  linked from the loop file before it is archived.

## Coordination with other rules

- [`handoff-routing.md`](handoff-routing.md) — when a stalled loop should
  become a handoff instead.
- [`safety.md`](safety.md) and [`execution-model.md`](execution-model.md) —
  gating destructive actions inside an iteration.
- [`memory-workflow.md`](memory-workflow.md) — durable record of a loop's
  outcome once closed.
- [`prompt-engineering.md`](prompt-engineering.md) — a verification/
  self-correction loop's stop condition is often a prompt eval passing.
