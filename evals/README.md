# Evals

Regression scenarios for the shared agent instruction set: rules, skills,
and profiles under `agents/`. These protect behavior the same way a test
suite protects code.

## Structure

- `templates/scenario.md` — scaffold for a new scenario.
- `scenarios/<slug>.md` — one file per protected behavior, with an
  append-only run log.

## Rules

See [`agents/rules/agent-regression-testing.md`](../agents/rules/agent-regression-testing.md).

1. Add a scenario before changing a rule/skill/profile other agents rely
   on, if no scenario already covers the behavior.
2. Record every run — append only, never rewrite a prior entry.
3. A failing most-recent run blocks calling the change done.

## Commands

Add a new scenario:

```
/eval-new <slug> "<behavior to protect>"
```

Record a run's outcome:

```
/eval-record <slug>
```
