---
name: eval-new
description: Add a new regression scenario protecting a rule, skill, or profile's behavior. Scaffolds evals/scenarios/<slug>.md from the template.
argument-hint: "<slug> \"<behavior to protect>\""
allowed-tools:
  - Bash
  - Read
  - Write
---

# Add a Regression Scenario

Scaffold a scenario so a change to a shared rule, skill, or profile has a
documented "before" to compare against, instead of relying on memory of
what the old behavior was.

Behavioral rules: `agents/rules/agent-regression-testing.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug> "<behavior to protect>"`. Reject the slug
   if it contains spaces or characters outside `a-z0-9-`.
2. Confirm `evals/scenarios/<slug>.md` does NOT already exist. If it does,
   tell the user to use `eval-record` instead.
3. Read `evals/templates/scenario.md`.
4. Write `evals/scenarios/<slug>.md`, replacing the `REPLACE-` tokens:
   - `scenario:` → `<slug>`.
   - `covers:` → ask the user which rule/skill/profile file(s) this
     protects, if not already obvious from context.
   - `created:` → current UTC time, ISO 8601.
   - `## Scenario` → seeded from the behavior description in
     `$ARGUMENTS`.
5. Leave `## Expected Behavior` and `## Run Log` as scaffolded
   placeholders for the conversation to fill in.
6. Print to the user:

   ```
   Created evals/scenarios/<slug>.md

   Next:
     1. Fill in Expected Behavior precisely — what the agent must do, and
        must not do.
     2. Walk through the scenario against current behavior before you
        change the rule/skill/profile it covers.
     3. After the change, run eval-record to log the outcome.
     4. Commit when ready:
          git add evals/scenarios/<slug>.md
          git commit -m "eval(new): <slug>"
   ```

7. Do NOT commit automatically. The scenario has no recorded run yet.

## Hard constraints

- Slug must be lowercase-kebab, no leading date required (scenarios are
  durable, not dated threads).
- Never overwrite an existing scenario file.
- Never include secrets in the scenario body.
