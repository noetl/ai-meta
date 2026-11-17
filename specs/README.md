# Specs

Spec-driven development artifacts: write the spec before the plan, the plan
before the code.

## Structure

- `templates/spec.md` — scaffold for a new spec.
- `active/<slug>/spec.md` — specs currently being drafted, reviewed, or
  implemented against.
- `archive/<slug>/spec.md` — specs that shipped (or were abandoned, noted as
  such) with every Acceptance Criteria bullet resolved.

## Where a spec lives

**File = truth. Issue = tracking. Wiki = reading room.**

- **File** (canonical) — repo-specific specs live in the owning repo's
  `specs/`; cross-repo and general specs live here in ai-meta's `specs/`.
- **Issue** — one coordination issue per spec in `noetl/ai-meta`, opened from
  the *Spec coordination* template. It links to the file and carries status,
  task breakdown, and PR links. It is not the spec.
- **Wiki** — [`docs/wiki/Specs-Index.md`](../docs/wiki/Specs-Index.md),
  published as the ai-meta wiki's **Specs Index**, is the browsable map. It
  indexes; it does not copy.

See [`agents/rules/spec-locations.md`](../agents/rules/spec-locations.md).

## Rules

See [`agents/rules/spec-driven-development.md`](../agents/rules/spec-driven-development.md).

1. A spec is not approved until its Open Questions are resolved in writing.
2. Acceptance Criteria must be checkable, not aspirational.
3. Plan items become tracked issues via the `spec-to-tasks` skill; issues
   cite the spec path back.
4. Archive only after every criterion is checked off and cited to a landing
   PR/commit.

## Commands

Open a new spec:

```
/spec-new <slug> "<one-line problem statement>"
```

Convert an approved spec's plan into tracked issues:

```
/spec-to-tasks <slug>
```
