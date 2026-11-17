---
name: Spec coordination
about: Tracking issue for one spec. Links to the canonical spec file; does not restate it.
title: "Spec: <slug> — <one-line purpose>"
labels: ["ai-task"]
---

<!--
  agents/rules/spec-locations.md — file = truth, issue = tracking, wiki = reading room.

  This issue TRACKS a spec. It does not contain one.
  Link the spec file; do not copy its acceptance criteria here — a second
  copy will drift from the first.
-->

## Spec file (canonical)

<!-- Required. Permalink to the spec, in the repo that owns the surface it changes. -->

- **Spec:** `<repo>/specs/active/<slug>/spec.md`
- **Link:** <!-- https://github.com/noetl/<repo>/blob/main/specs/active/<slug>/spec.md -->
- **Scope:** repo-specific / cross-repo / general
- **Owning repo:** <!-- the repo whose surface this changes -->

## Status

<!-- Mirrors the spec file's frontmatter `status:`. The file changes first; this follows. -->

- **Status:** draft / approved / implementing / verifying / shipped / abandoned
- **Last updated:** <!-- YYYY-MM-DD -->

Open Questions resolved? <!-- yes / no — a spec with open questions is not approved -->

## Task breakdown

<!--
  One line per Plan item from the spec. Opened as child issues by
  `spec-to-tasks`; each cites the spec path in its own ## Pointers.
  Check a box only when the corresponding item has actually landed.
-->

- [ ] <!-- plan item 1 → #NNN -->
- [ ] <!-- plan item 2 → #NNN -->

## Linked PRs

<!-- Every PR implementing against this spec, with the repo it landed in. -->

| PR | Repo | Lands |
| :-- | :-- | :-- |
|  |  |  |

## Acceptance criteria

Tracked in the spec file — see its `## Acceptance Criteria` section. Record
here only **which** criteria are satisfied and by what evidence, not the
criteria themselves:

- [ ] AC<N> — evidence: <!-- PR, run link, measurement -->

## Verification

<!-- How the spec's Verification Plan was actually exercised. Evidence, not intent. -->

## Notes / discussion

<!-- Free-form. Decisions that change the spec must land in the FILE first. -->
