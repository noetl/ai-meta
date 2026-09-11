# Spec-Driven Change Playbook

Canonical checklist for a non-trivial feature or cross-file/cross-repo
change: spec first, then tasks, then implementation, then verification
against the spec — not just against test pass/fail.

## Inputs

- Problem statement
- Affected repositories or project areas
- Stakeholders who must sign off on Open Questions

## Steps

1. `/spec-new <slug> "<problem statement>"` — scaffold the spec.
2. Fill in Goals, Non-Goals, Constraints, and checkable Acceptance Criteria.
3. Resolve every Open Questions bullet in writing with stakeholders. A spec
   with open questions is not approved.
4. Commit: `spec(new): <slug>`.
5. `/spec-to-tasks <slug>` — convert the Plan / Task Breakdown into tracked
   issues, each citing the spec path.
6. Implement per issue, in the source tree that owns the code. Follow
   `playbooks/cross_repo_change.md` when the work spans repos.
7. Verify each Acceptance Criteria bullet against the spec's Verification
   Plan before closing its issue.
8. Once every bullet is checked off and cited to a landing PR/commit,
   archive the spec (`specs/active/<slug>/` → `specs/archive/<slug>/`).
9. If any decisions from the spec are durable technical reference, promote
   them to wiki/docs memory per `agents/rules/wiki-maintenance.md` before
   archiving.

## Output

- Approved spec with resolved Open Questions
- Linked tracked issues, one per plan item
- Verification evidence per Acceptance Criteria bullet
- Archived spec citing landing PRs/commits

See `agents/rules/spec-driven-development.md`.
