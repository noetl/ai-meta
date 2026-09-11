# Loops

Definitions for repeatable agent loops: retry loops, plan-execute-verify
loops, autonomous background loops, self-correction loops, CI-fix loops.
A loop's goal, bounds, and progress are recorded here so a future session or
agent can resume or audit it, the same way handoffs and memory are recorded.

## Structure

- `templates/loop.md` — scaffold for a new loop definition.
- `active/<slug>/loop.md` — loops currently running or paused, with
  iteration checkpoints appended as they happen.
- `archive/<slug>/loop.md` — closed loops, with a recorded outcome
  (`converged`, `stopped-at-bound`, or `escalated`).

## Rules

See [`agents/rules/loop-engineering.md`](../agents/rules/loop-engineering.md).

1. No loop starts without an explicit stop condition and hard bounds (max
   iterations / time / cost) recorded first.
2. Each iteration's meaningful outcome is appended, not overwritten.
3. Destructive actions inside an iteration are gated like a handoff phase.
4. A loop that escalates must link the resulting issue or handoff before it
   is archived.

## Commands

Open a new loop:

```
/loop-new <slug> "<goal>"
```

Close a loop (record outcome, archive):

```
/loop-close <slug>
```
