# Spec-Driven Development

For any non-trivial feature or cross-file/cross-repo change, write the spec
before the plan and the plan before the code. The spec is the source of
truth for acceptance criteria; tracked issues execute against it, and
verification checks the spec's criteria, not just "tests pass."

## Where specs live

- `specs/active/<slug>/spec.md` — one directory per spec, scaffolded from
  `specs/templates/spec.md`.
- Shipped or abandoned specs move to `specs/archive/<slug>/`.
- Use the `spec-new` skill to open one, `spec-to-tasks` to convert an
  approved spec's plan into tracked issues.

## Spec sections

1. `## Problem` — what is wrong or missing, and for whom.
2. `## Goals` / `## Non-Goals` — explicit scope boundaries.
3. `## Constraints` — technical, org, or timeline constraints that shape the
   solution space.
4. `## Acceptance Criteria` — checkable bullets. Each one must be
   verifiable by a test, a demo, or an explicit review step — not a vague
   aspiration.
5. `## Plan / Task Breakdown` — ordered, concrete implementation steps.
6. `## Open Questions` — anything unresolved. A spec with open questions is
   not approved.
7. `## Verification Plan` — how each acceptance criterion will actually be
   checked before the spec is archived as shipped.
8. `## Linked Issues` — filled in by `spec-to-tasks`.

## Workflow

1. Draft the spec (`status: draft`) with Problem, Goals, Non-Goals, and a
   first-pass Acceptance Criteria list.
2. Resolve every Open Questions bullet with the user or stakeholders before
   treating the spec as approved. "Resolved" means the answer is written
   into the spec, not merely discussed in chat.
3. Run `spec-to-tasks` to turn each Plan item into a tracked issue (see
   [`issue-tracking.md`](issue-tracking.md)), with the issue's
   `## Pointers` section citing the spec path.
4. Implement per issue, in the source tree that owns the code (see
   [`submodules.md`](submodules.md) when linked repos are involved).
5. Verify against the spec's Acceptance Criteria and Verification Plan, not
   only against test-suite pass/fail. Close each issue only when its
   corresponding criterion is actually satisfied.
6. Archive the spec once every Acceptance Criteria bullet is checked off and
   cited to a landing PR/commit.

## Rules

- Do not start multi-file or cross-repo implementation on a non-trivial
  change without a spec whose Open Questions are resolved, not just listed.
- Acceptance criteria must be checkable. Reject vague criteria like "works
  well" — rewrite them as a test, a demo script, or a specific reviewable
  behavior.
- A spec is append-only once shared for review: log scope changes as new
  dated notes under the spec rather than silently rewriting Goals or
  Acceptance Criteria after implementation has started. If scope genuinely
  changes, say so explicitly and note why.
- When a spec's decisions are durable technical reference (not just a
  one-time change), promote the relevant parts to wiki/docs memory per
  [`wiki-maintenance.md`](wiki-maintenance.md) before archiving.

## Coordination with other rules

- [`issue-tracking.md`](issue-tracking.md) — Plan items become tracked
  issues; a spec is the umbrella context those issues point back to.
- [`roadmap-boards.md`](roadmap-boards.md) — issues opened from a spec still
  follow normal board lifecycle.
- [`wiki-maintenance.md`](wiki-maintenance.md) — durable decisions from a
  shipped spec may warrant a wiki/docs page.
- [`loop-engineering.md`](loop-engineering.md) — an implementation loop's
  Goal should reference the spec's Acceptance Criteria it is trying to
  satisfy.
- `playbooks/cross_repo_change.md` and `playbooks/spec_driven_change.md` —
  operational checklists that use this rule.
