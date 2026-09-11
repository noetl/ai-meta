# Definition of Done (Default, Lightweight)

Most day-to-day work is smaller than a spec deserves. This rule gives that
work a default completion checklist so it is neither over-specced nor
under-verified.

## Default checklist

Before calling a task done:

1. The change matches what was actually asked — re-read the request
   against the diff.
2. Local validation ran where applicable (tests, build, lint) — see
   [`deployment-validation.md`](deployment-validation.md) for
   runtime-impacting changes.
3. The commit message follows
   [`commit-conventions.md`](commit-conventions.md).
4. If the task represents a decision or outcome worth recalling later, a
   memory entry was added — see [`memory-workflow.md`](memory-workflow.md).
5. If a tracked issue/ticket exists for the task, its status reflects what
   actually landed — see [`issue-tracking.md`](issue-tracking.md).
6. No secrets, tokens, or credentials were introduced — see
   [`safety.md`](safety.md).
7. If the change touched a public surface (API, config, schema, behavior),
   docs/wiki coverage was updated in the same change set — see
   [`wiki-maintenance.md`](wiki-maintenance.md).

## When this checklist is not enough

Escalate to a full spec (`spec-new`, see
[`spec-driven-development.md`](spec-driven-development.md)) instead of
pushing a large change through this lightweight path when any of these is
true:

- The work spans multiple sessions or multiple repositories.
- Acceptance criteria need stakeholder sign-off before implementation.
- The task has Open Questions that materially change scope depending on
  the answer.
- Multiple agents will touch the same task and need a shared reference.

Escalate to a tracked issue (`issue-open`, see
[`issue-tracking.md`](issue-tracking.md)) when the work needs to survive
session compaction even if it doesn't need a full spec.

## Rules

- Don't skip the checklist because a task feels small — run it, briefly;
  it costs seconds and catches missed memory/issue/docs updates.
- Don't write a full spec for a task this checklist already covers — that
  is manufactured overhead in the other direction.
- If a task starts small and grows mid-session past the "when this
  checklist is not enough" bullets, stop and open a spec or issue rather
  than continuing to expand an unrecorded task.

## Coordination with other rules

- [`spec-driven-development.md`](spec-driven-development.md) — the
  upgrade path when scope grows.
- [`issue-tracking.md`](issue-tracking.md) — the upgrade path when
  durability, not scope, is the issue.
- [`memory-workflow.md`](memory-workflow.md),
  [`commit-conventions.md`](commit-conventions.md),
  [`deployment-validation.md`](deployment-validation.md), and
  [`wiki-maintenance.md`](wiki-maintenance.md) — the specific checklist
  items above.
