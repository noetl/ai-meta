# Agent Regression Testing Playbook

Canonical checklist for changing a shared rule, skill, or profile without
silently breaking behavior other agents rely on.

## Steps

1. Before changing a rule/skill/profile file under `agents/`, check
   `evals/scenarios/` for one covering the behavior you're about to touch.
2. If none exists and the change is substantive, run `/eval-new <slug>
   "<behavior>"` first, so there is a documented expectation before the
   change lands.
3. Make the change.
4. Walk through the scenario manually against the new behavior.
5. Run `/eval-record <slug>` — log pass/fail, commit SHA, and a short
   note.
6. If the result is `fail`, fix forward and record a new run; never
   delete or edit the failing entry.
7. Commit the rule/skill/profile change, citing the scenario(s) checked
   in the commit body.

## Output

- A scenario file with an append-only run log showing the behavior was
  checked before and after the change.

See `agents/rules/agent-regression-testing.md`.
