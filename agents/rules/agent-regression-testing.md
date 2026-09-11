# Agent Regression Testing

Rule files, skills, and profiles are code for agent behavior. A change to
any of them can silently break behavior other agents or sessions rely on —
the same risk a code change carries, and the same discipline applies:
regression coverage before merge.

## Where scenarios live

- `evals/scenarios/<slug>.md` — one file per behavior worth protecting,
  scaffolded from `evals/templates/scenario.md`.
- Use the `eval-new` skill to add one, `eval-record` to log a run's
  outcome against it.

## What a scenario captures

1. **Covers** — the rule/skill/profile file(s) whose behavior this
   scenario protects.
2. **Scenario** — a concrete situation an agent will plausibly encounter
   (e.g. "asked to bump a pointer with an open acceptance criterion still
   unmet").
3. **Expected Behavior** — what the agent must do, and must not do.
4. **Run Log** — append-only: date, commit SHA, agent/model, pass/fail,
   and a short note. Never rewritten; only appended.

## When to add or update a scenario

- Before changing a rule, skill, or profile that other agents depend on,
  check whether an existing scenario covers the behavior. If not, add one
  with `eval-new` before making the change, so there's a documented
  "before" to compare against.
- After the change, walk through the scenario manually (there is no
  automated harness here) and record the result with `eval-record`.
- A rule/skill/profile change with no scenario covering its observable
  behavior is a signal the change is either low-risk enough to skip, or
  under-tested — decide explicitly; don't skip silently for a substantive
  behavior change.

## Rules

- Never overwrite a prior Run Log entry — append only, the same
  discipline [`memory-workflow.md`](memory-workflow.md) and
  [`prompt-engineering.md`](prompt-engineering.md) changelogs use.
- A scenario whose most recent run is marked `fail` blocks treating the
  corresponding rule/skill change as done; fix forward and record a new
  run — don't delete or edit the failing entry to hide it.
- Keep scenarios concrete and grep-able (real commands, real file paths)
  rather than abstract descriptions — the same standard
  [`handoffs.md`](handoffs.md) sets for result fingerprints.

## Coordination with other rules

- [`prompt-engineering.md`](prompt-engineering.md) — prompt eval notes
  cover one prompt's behavior; this rule covers the shared instruction set
  (rules, skills, profiles) that every agent reads.
- [`handoffs.md`](handoffs.md) — a scenario can be the concrete thing a
  dispatcher asks an executor to verify still holds after a change.
- [`commit-conventions.md`](commit-conventions.md) — `docs(agents):`
  commits that change shared behavior should cite the scenario(s) checked
  in the commit body.
- [`context-engineering.md`](context-engineering.md) — a scenario's
  Expected Behavior should be checkable without reloading unrelated
  history.
