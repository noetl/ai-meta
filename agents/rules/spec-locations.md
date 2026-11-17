# Spec Locations — file, issue, wiki

A spec exists in three places at once, and they are not interchangeable.
This rule says which one is authoritative, what the other two are for, and
where a given spec's file belongs.

## The principle

**File = truth. Issue = tracking. Wiki = reading room.**

Only a file in a repository gives the three things a spec needs to be
trustworthy:

- **Review before acceptance.** A spec file lands through a PR, so its
  acceptance criteria are argued over *before* anyone implements against
  them. An issue body is edited in place, after the fact, by whoever has
  write access.
- **A clean diff.** "What changed in this spec, when, and who approved it"
  is `git log -p`. Issue-body edit history is not reviewable and not
  diffable.
- **CI enforcement.** A file can be linted, link-checked, and gated. An
  issue body cannot.

An issue or a wiki page that disagrees with the spec file is wrong by
definition — fix it to match, do not treat it as a second opinion. This is
[`representation-drift.md`](representation-drift.md) applied to specs: the
issue and the wiki are copies, true only while something forces them to
agree.

## Where the canonical file lives

| Scope of the spec | Canonical location |
| :-- | :-- |
| Changes one repo's own surface | that repo's `specs/active/<slug>/spec.md` |
| Spans repos, or is general/architectural | ai-meta's `specs/active/<slug>/spec.md` |

Pick by **who owns the surface the spec changes**, not by who happens to be
writing it. A spec that only moves `noetl/server` internals belongs in
`noetl/server`, even when an ai-meta session drafts it. A spec that
coordinates server + worker + ops belongs in ai-meta.

If the owning repo has no `specs/` tree yet, scaffold it from the template
(see [`spec-driven-development.md`](spec-driven-development.md)) in the same
PR as the first spec, rather than parking a repo-specific spec in ai-meta
because it is convenient.

Shipped or abandoned specs move to `specs/archive/<slug>/` in the repo that
owns them.

## The coordination issue

Every spec gets **one** tracked issue in `noetl/ai-meta`, opened from the
`spec-coordination` issue template. It carries what a file is bad at:
status over time, discussion, task breakdown, and links to the PRs that
implement it. It lives on the project board per
[`roadmap-boards.md`](roadmap-boards.md).

The issue **links to the spec file and does not restate it.** Copying
acceptance criteria into the issue body creates a second copy that will
drift from the first; link to the file's section instead.

Per-plan-item issues opened by `spec-to-tasks` are children of this
coordination issue and cite the spec path in their `## Pointers`.

## The wiki index

The ai-meta wiki carries a **Specs Index** page: the browsable map of
general and cross-repo specs, with each entry linking to the canonical file
and its coordination issue. Each project repo's wiki does the same for its
own repo-level specs.

The index is a **pointer list, not a copy.** It records slug, one-line
purpose, status, and the two links. It does not reproduce the spec's
content, so it cannot contradict it — the worst it can be is out of date on
status, which the index makes obvious by showing the file link next to it.

## Rules

- Never treat an issue body or a wiki page as the spec. If they disagree
  with the file, the file wins and the copy gets fixed in the same change
  set.
- Never open a coordination issue without linking the spec file. An issue
  with acceptance criteria and no file behind them is a spec that was never
  reviewed.
- Do not restate acceptance criteria in the issue or the wiki — link to the
  file's section.
- A spec's status changes in the file's frontmatter first; the issue and the
  index follow in the same change set, the same way
  [`issue-tracking.md`](issue-tracking.md) Rule 2 couples issue updates to
  the code.
- When a spec is archived, move the file, close the coordination issue with
  the landing citation, and move the index entry to the archived section —
  all three, or the index quietly starts advertising specs that shipped
  months ago as active.

## Coordination with other rules

- [`spec-driven-development.md`](spec-driven-development.md) — what a spec
  contains and its lifecycle; this rule only says where each artifact lives.
- [`issue-tracking.md`](issue-tracking.md) — issue conventions, labels, and
  the update-in-the-same-change-set discipline the coordination issue follows.
- [`roadmap-boards.md`](roadmap-boards.md) — the coordination issue goes on
  the board like any other `ai-task` issue.
- [`wiki-maintenance.md`](wiki-maintenance.md) — which wiki owns what, and
  the rule that a wiki change set rides with the work.
- [`representation-drift.md`](representation-drift.md) — the general form of
  "the copy is only true while something forces it to agree."
- [`context-engineering.md`](context-engineering.md) — prefer loading the
  index or the issue over the full spec when the task does not need the
  whole thing.

## History

Codified 2026-09-11, after the spec/loop framework landed in
[#333](https://github.com/noetl/ai-meta/pull/333) and the first real spec
(`2026-09-11-d3-projection-serve-flip`) needed a home for its status and a
place to be found from. The three-layer split was already implicit in
[`spec-driven-development.md`](spec-driven-development.md); this rule makes
the ownership explicit so the issue does not slowly become the spec.
