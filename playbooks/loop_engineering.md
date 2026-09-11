# Loop Engineering Playbook

Canonical checklist for running a repeatable agent loop (retry,
plan-execute-verify, self-correction, CI-fix, autonomous background loop)
without it running unbounded or losing state on interruption.

## Inputs

- A concrete, checkable goal
- A budget (max iterations / wall-clock / cost) the user or project accepts

## Steps

1. `/loop-new <slug> "<goal>"` — scaffold the loop definition.
2. Fill in Stop Conditions (success condition AND hard bounds) and the
   Escalation Path before running a single iteration.
3. Commit: `loop(open): <slug>`.
4. Run iterations. After each one, append a dated entry under
   `## Iterations` in `loops/active/<slug>/loop.md` — attempt summary, diff
   reference, test result. State must be resumable from this record.
5. Gate any destructive action inside an iteration (push, deploy, cancel,
   merge) the same way a handoff phase is gated — see
   `agents/rules/safety.md`.
6. Stop when the success condition is met, or when a hard bound is hit.
7. If a hard bound is hit without success, follow the recorded Escalation
   Path: open a tracked issue or a handoff thread, and link it from the
   loop file.
8. `/loop-close <slug>` — record the outcome (`converged` /
   `stopped-at-bound` / `escalated`) and archive.

## Output

- Loop file with a full iteration record
- Outcome status and, if escalated, a linked issue or handoff

See `agents/rules/loop-engineering.md` and `agents/rules/handoff-routing.md`
for when a stalled loop should become a handoff instead of widening its
bounds.
