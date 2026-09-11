---
name: loop-new
description: Open a new agent loop definition. Scaffolds loops/active/<slug>/loop.md from the template with goal, stop conditions, and escalation path to be filled in before the loop runs.
argument-hint: "<slug> \"<goal>\""
allowed-tools:
  - Bash
  - Read
  - Write
---

# Open a New Loop

Scaffold a loop definition so a repeatable agent loop (retry, plan-execute-
verify, self-correction, CI-fix) has an explicit goal, stop conditions, hard
bounds, and escalation path before any iteration runs.

Behavioral rules: `agents/rules/loop-engineering.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug> "<goal>"`. Reject the slug if it contains
   spaces or characters outside `a-z0-9-`. Prepend today's UTC date
   (`YYYY-MM-DD-`) if not already present.
2. Confirm `loops/active/<slug>/` does NOT already exist. If it does, abort
   and tell the user to continue the existing loop or pick a new slug.
3. `mkdir -p loops/active/<slug>/`.
4. Read `loops/templates/loop.md`.
5. Write `loops/active/<slug>/loop.md`, replacing the `REPLACE-` tokens:
   - `loop:` → the full slug.
   - `created:` → current UTC time, ISO 8601.
   - `owner:` → the current agent or user, if known.
   - `## Goal` → seeded from the goal in `$ARGUMENTS`.
6. Leave `## Stop Conditions`, `## Checkpoint Cadence`, `## State Source`,
   and `## Escalation Path` as scaffolded placeholders — this skill creates
   the file but does not decide bounds. Continue the conversation with the
   user to fill these in before starting iterations.
7. Print to the user:

   ```
   Created loops/active/<slug>/loop.md

   Next:
     1. Fill in Stop Conditions (success AND hard bounds: max iterations /
        wall-clock / cost) and Escalation Path before running any
        iteration. A loop without hard bounds must not start.
     2. Commit when ready:
          git add loops/active/<slug>/loop.md
          git commit -m "loop(open): <slug>"
     3. Append an entry under Iterations after each meaningful step.
     4. Run loop-close when the loop ends, to record the outcome.
   ```

8. Do NOT commit automatically, and do NOT begin executing loop iterations
   until Stop Conditions and Escalation Path are filled in.

## Hard constraints

- Slug must be `<YYYY-MM-DD>-<lowercase-kebab-topic>`.
- Never overwrite an existing loop file.
- Never start iterations before hard bounds (max iterations/time/cost) are
  recorded — no unbounded loops.
- Never include secrets in the loop file.
