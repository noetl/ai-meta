---
name: prompt-new
description: Create a new versioned prompt in the prompt library. Scaffolds prompts/library/<name>.md from the template at version 1, status draft.
argument-hint: "<name> \"<one-line intent>\""
allowed-tools:
  - Bash
  - Read
  - Write
---

# Create a New Prompt

Scaffold a prompt file so a reusable prompt is versioned, testable, and
durable instead of living only in chat history.

Behavioral rules: `agents/rules/prompt-engineering.md`.

## Steps

1. Parse `$ARGUMENTS` as `<name> "<intent>"`. Reject the name if it contains
   characters outside `a-z0-9-`.
2. Confirm `prompts/library/<name>.md` does NOT already exist. If it does,
   tell the user to use `prompt-iterate` instead.
3. Read `prompts/templates/prompt.md`.
4. Write `prompts/library/<name>.md`, replacing the `REPLACE-` tokens:
   - `name:` → `<name>`.
   - `version: 1`, `status: draft`.
   - `target_models:` → ask the user if not obvious from context.
   - `created:` → current UTC time, ISO 8601.
   - `## Intent` → seeded from `<intent>`.
5. Leave `## Prompt Body`, `## Known Failure Modes`, and `## Eval Notes` as
   scaffolded placeholders for the conversation to fill in.
6. Print to the user:

   ```
   Created prompts/library/<name>.md

   Next:
     1. Fill in the Prompt Body (the literal, copy-pasteable text) and
        Inputs / Variables.
     2. Test against representative inputs, including edge cases, before
        promoting status to "stable".
     3. Record the outcome in Eval Notes.
     4. Commit when ready:
          git add prompts/library/<name>.md
          git commit -m "prompt(add): <name>"
   ```

7. Do NOT commit automatically. The scaffold has no tested prompt body yet.

## Hard constraints

- Never overwrite an existing prompt file — use `prompt-iterate`.
- Never write `status: stable` from this skill; that requires eval notes,
  which only exist after testing.
- Never bake secrets or credentials into the prompt body.
