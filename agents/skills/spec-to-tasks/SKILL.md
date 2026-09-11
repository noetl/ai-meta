---
name: spec-to-tasks
description: Convert an approved spec's Plan / Task Breakdown into tracked issues, each citing the spec path back.
argument-hint: "<slug>"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Convert a Spec into Tracked Tasks

Turn a spec's plan into durable, trackable work items so implementation
survives session compaction and is visible to every agent that picks it up
next.

Behavioral rules: `agents/rules/spec-driven-development.md` and
`agents/rules/issue-tracking.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug>`. Confirm `specs/active/<slug>/spec.md`
   exists. If not, abort and tell the user to check the slug.
2. Read the spec. Confirm:
   - `## Open Questions` has no unresolved bullets. If any remain, abort and
     list them — the spec is not approved.
   - `## Acceptance Criteria` has at least one checkable bullet. If empty or
     vague, abort and ask the user to make it checkable first.
3. Read `## Plan / Task Breakdown`. For each concrete plan item, follow the
   `issue-open` skill's steps to draft an issue:
   - Title: an imperative action phrase under 70 characters, derived from
     the plan item.
   - Body includes `## Context`, `## Goal`, `## Pointers` (must cite
     `specs/active/<slug>/spec.md`), `## Blocked on`, `## Links`.
4. Public-safety check the drafted issue bodies before creating them (no
   secrets, tokens, or customer data).
5. Create each issue with the project's tracker command, same as
   `issue-open`.
6. Update the spec's `## Linked Issues` section with the resulting issue
   links.
7. If the project uses roadmap boards, add each issue to the correct board.
8. Print the created issue URLs and the updated spec path.
9. Stage and commit:
   ```
   git add specs/active/<slug>/spec.md
   git commit -m "spec(tasks): <slug>"
   ```
   Ask the user before pushing.

## Hard constraints

- Refuse to convert a spec with unresolved Open Questions.
- Refuse to convert a spec with empty or non-checkable Acceptance Criteria.
- Do not open duplicate issues for plan items already tracked; search first.
- Never include secrets. Specs and issues are durable, often public,
  artifacts.
