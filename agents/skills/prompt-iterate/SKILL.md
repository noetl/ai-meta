---
name: prompt-iterate
description: Revise an existing prompt — version bump, append-only changelog entry, and eval note. Never silently edits a prompt in place.
argument-hint: "<name>"
allowed-tools:
  - Bash
  - Read
  - Edit
---

# Iterate a Prompt

Apply a semantic change to an existing prompt as a tracked version bump, not
a silent edit.

Behavioral rules: `agents/rules/prompt-engineering.md`.

## Steps

1. Parse `$ARGUMENTS` as `<name>`. Confirm `prompts/library/<name>.md`
   exists. If not, tell the user to use `prompt-new` instead.
2. Read the current file. Note the current `version` and `status`.
3. Discuss with the user what is changing in the Prompt Body and why.
4. Edit the file:
   - Update the Prompt Body with the new text.
   - Bump `version:` in frontmatter by 1.
   - Append (do not rewrite) a new line under `## Changelog`:
     `- vN (<date>): <what changed and why>`.
   - Append a new line under `## Eval Notes` once the user reports a test
     outcome: `- vN (<date>): <inputs tested, result>`.
   - If the change fixes a known failure mode, update `## Known Failure
     Modes` to reflect current status rather than deleting the historical
     note — mark it resolved-at-vN instead of removing it.
   - Update `status:` only if the user confirms eval results support the
     transition (`draft` → `stable`, or `stable`/`draft` → `deprecated` with
     the replacement noted in the changelog line).
5. Print a summary of the version bump and ask if the user wants to commit:
   ```
   git add prompts/library/<name>.md
   git commit -m "prompt(iterate): <name> vN"
   ```

## Hard constraints

- Never edit or delete a prior `## Changelog` or `## Eval Notes` entry —
  append only.
- Never bump `status` to `stable` without a corresponding eval note recorded
  in the same edit or a prior one.
- Never bake secrets or credentials into the prompt body.
