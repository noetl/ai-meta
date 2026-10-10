# Specs Index

The map of **general and cross-repo specs**. Repo-specific specs are indexed
on their own repo's wiki, not here.

> **This page is an index, not a spec.** Every entry links to the canonical
> file; nothing here restates a spec's content. If this page and a spec file
> disagree, the file is right and this page is stale — fix it.
> See [`agents/rules/spec-locations.md`](https://github.com/noetl/ai-meta/blob/main/agents/rules/spec-locations.md).

**File = truth. Issue = tracking. Wiki = reading room.**

| | |
| :-- | :-- |
| **File** | the spec itself — reviewed in a PR, diffable, CI-checkable |
| **Issue** | status, discussion, task breakdown, PR links; lives on the board |
| **Wiki** | this index — how to find the other two |

## Active

| Spec | Purpose | Status | Issue |
| :-- | :-- | :-- | :-- |
| [`2026-09-11-d3-projection-serve-flip`](https://github.com/noetl/ai-meta/blob/main/specs/active/2026-09-11-d3-projection-serve-flip/spec.md) | Let a *behind* D3 snapshot serve reads; make an *ahead* snapshot unserveable | `draft` — Open Questions unresolved, **not approved** | [#336](https://github.com/noetl/ai-meta/issues/336) |

⚠ The D3 spec file lands via [#334](https://github.com/noetl/ai-meta/pull/334)
(open). Until that merges, the link above 404s on `main` — read it on the
`spec/d3-projection-serve-flip` branch.

## Archived

*(none yet — specs move here from `specs/active/` once every acceptance
criterion is checked off and cited to a landing PR, per
[`spec-driven-development.md`](https://github.com/noetl/ai-meta/blob/main/agents/rules/spec-driven-development.md).)*

| Spec | Outcome | Shipped | Issue |
| :-- | :-- | :-- | :-- |
| — | — | — | — |

## Repo-level spec indexes

A spec that changes one repo's own surface lives in that repo and is indexed
on that repo's wiki. Add a row here only when a repo grows its first spec.

| Repo | Specs index |
| :-- | :-- |
| *(none yet)* | — |

## Adding a spec to this index

1. Land the spec file in the repo that owns the surface it changes
   (`specs/active/<slug>/spec.md`).
2. Open its coordination issue from the **Spec coordination** issue template
   in `noetl/ai-meta`, and add it to
   [board 3](https://github.com/orgs/noetl/projects/3/views/1).
3. Add one row above: slug (linked to the file), one-line purpose, status
   mirroring the file's frontmatter, and the issue number.
4. On archive: move the row to **Archived**, close the issue with the
   landing citation, and move the file to `specs/archive/<slug>/` — all
   three in the same change set.

## Maintenance

This page is published from
[`docs/wiki/Specs-Index.md`](https://github.com/noetl/ai-meta/blob/main/docs/wiki/Specs-Index.md)
in `noetl/ai-meta`. Edit the file and republish; do not hand-edit the wiki
page, or the two will diverge and the file will lose.

Per [`wiki-maintenance.md`](https://github.com/noetl/ai-meta/blob/main/agents/rules/wiki-maintenance.md)
Rule 0a, a session that opens, ships, or archives a spec updates this index
in the same change set as the work.
