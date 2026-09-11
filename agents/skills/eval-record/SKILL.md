---
name: eval-record
description: Append a run outcome (pass/fail) to an existing regression scenario's run log after checking a rule/skill/profile change against it.
argument-hint: "<slug>"
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Record a Scenario Run

Log what actually happened when a scenario was checked, so the run log is
a durable record instead of a claim made only in chat.

Behavioral rules: `agents/rules/agent-regression-testing.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug>`. Confirm `evals/scenarios/<slug>.md`
   exists. If not, tell the user to use `eval-new` instead.
2. Determine:
   - Current UTC date.
   - Current short SHA: `git rev-parse --short HEAD`.
   - Current agent/model name.
   - Outcome: `pass` or `fail`, based on walking through the scenario's
     `## Expected Behavior` against what actually happened.
   - A short, concrete note (what was checked, what happened — grep-able,
     not vague).
3. Edit the file: append one line under `## Run Log` in the form
   `- <date>, <short-sha>, <agent>: <pass|fail> — <note>`. Never rewrite or
   remove a prior line.
4. If the outcome is `fail`, tell the user this scenario now blocks
   treating the associated rule/skill/profile change as done — fix
   forward and record a new run; do not delete or edit the failing entry
   to hide it.
5. Print the appended line and ask if the user wants to commit:
   ```
   git add evals/scenarios/<slug>.md
   git commit -m "eval(record): <slug>"
   ```

## Hard constraints

- Never edit or delete a prior `## Run Log` line — append only.
- Never record a `pass` without actually having walked through the
  scenario against current behavior.
