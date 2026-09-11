---
name: spec-new
description: Open a new spec for spec-driven development. Scaffolds specs/active/<slug>/spec.md from the template.
argument-hint: "<slug> \"<one-line problem statement>\""
allowed-tools:
  - Bash
  - Read
  - Write
---

# Open a New Spec

Scaffold a spec so a non-trivial feature or cross-file/cross-repo change gets
a written problem statement, acceptance criteria, and plan before
implementation starts.

Behavioral rules: `agents/rules/spec-driven-development.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug> "<problem statement>"`. Reject the slug if
   it contains spaces or characters outside `a-z0-9-`. Prepend today's UTC
   date (`YYYY-MM-DD-`) if the slug doesn't already start with one.
2. Confirm `specs/active/<slug>/` does NOT already exist. If it does, abort
   and tell the user to either continue the existing spec or pick a new
   slug.
3. `mkdir -p specs/active/<slug>/`.
4. Read `specs/templates/spec.md`.
5. Write `specs/active/<slug>/spec.md`, replacing the `REPLACE-` tokens:
   - `spec:` → the full slug.
   - `created:` → current UTC time, ISO 8601.
   - `owner:` → the current agent or user, if known.
   - Body title and `## Problem` → seeded from the problem statement in
     `$ARGUMENTS`.
6. Leave Goals, Non-Goals, Constraints, Acceptance Criteria, Plan, Open
   Questions, and Verification Plan as scaffolded placeholders — this skill
   creates the file but does not fill in the substance. Continue the
   conversation with the user to flesh out the spec before it is treated as
   approved.
7. Print to the user:

   ```
   Created specs/active/<slug>/spec.md

   Next:
     1. Fill in Goals, Non-Goals, Acceptance Criteria (must be checkable),
        and Plan / Task Breakdown.
     2. Resolve every Open Questions bullet in writing — a spec is not
        approved while any remain.
     3. Commit when ready:
          git add specs/active/<slug>/spec.md
          git commit -m "spec(new): <slug>"
     4. Once approved, run spec-to-tasks to convert the Plan into tracked
        issues.
   ```

8. Do NOT commit automatically. The scaffold alone has no acceptance
   criteria yet.

## Hard constraints

- Slug must be `<YYYY-MM-DD>-<lowercase-kebab-topic>`.
- Never overwrite an existing spec file.
- Never mark a spec `status: draft` → approved in this skill; approval
  happens when Open Questions are resolved, which this skill cannot verify
  on its own.
- Never include secrets in the spec body.
