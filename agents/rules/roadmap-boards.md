# Roadmap Boards

NoETL coordinates work across many repos. The **GitHub Projects v2
boards** under the `noetl` org are the public, queryable shape of
"what's happening right now and what's queued next" across that
fleet. This rule keeps those boards in lockstep with the underlying
ai-task issues so the boards stay a usable single-pane view instead
of drifting into stale Todo columns.

This rule is the projects-board sibling of
[`issue-tracking.md`](issue-tracking.md) (issue lifecycle) and
[`wiki-maintenance.md`](wiki-maintenance.md) Rule 0a (wiki
dashboard freshness). The three trails get touched in the same
change set when substantive work moves.

## Board registry

Boards we own and update. Add new rows here when a new board is
created — that is the single edit that brings the board into the
discipline below.

| ID | Name | URL | Scope | Status field options |
| :-- | :-- | :-- | :-- | :-- |
| 3 | moetl-roadmap-project | <https://github.com/orgs/noetl/projects/3/views/1> | Cross-repo ai-task umbrellas (the default board for ai-meta issues) | Todo / In progress / Done |
| 2 | NoETL AI Runtime Program | <https://github.com/orgs/noetl/projects/2> | Strategic program tracking — long-lived initiatives, quarter-scoped | (program-specific) |

Until the rule says otherwise, **board 3 is the default home for
every `ai-task`-labelled issue in `noetl/ai-meta`**. Other boards
opt in by scope (program tracking, customer-specific roadmaps,
internal infra) and the table here records which scope each board
owns.

### Discovery incantation

```bash
gh project list --owner noetl
gh project field-list <PROJECT_NUMBER> --owner noetl --format json | jq .
gh project item-list <PROJECT_NUMBER> --owner noetl --format json | jq .
```

If a new project is found that isn't in the registry above, add the
row in the same change set as the first item that lands on it.

## Rule 1 — every new ai-task issue lands on its board

When [`issue-tracking.md`](issue-tracking.md) Rule 1 fires (open
an issue on first touch of substantive work), the issue is added
to its scoped board in the **same change set**. Workflow auto-add
is best-effort; the rule still requires the agent to confirm the
item is present.

```bash
gh project item-add 3 --owner noetl --url <ISSUE_URL>
```

`gh project item-add` is idempotent — if the item is already on
the board the command exits 0. Run it after every `gh issue
create` for an `ai-task` issue.

If the issue belongs on a non-default board (e.g. a program-scoped
initiative going on board 2), use the matching project number from
the registry and skip board 3.

## Rule 2 — status sync on lifecycle transitions

The issue's status on the board MUST match its lifecycle state.
Update the board column in the **same change set** that moves the
issue forward.

| Issue transition | Board status |
| :-- | :-- |
| New issue opened, nobody working on it yet | Todo |
| Work started (first PR opened, branch pushed, kind-validation begun, handoff round 1 dispatched) | In progress |
| All planned rounds shipped + umbrella issue closed | Done |
| Blocked on external action (human decision, upstream PR, missing endpoint) | Stay in current column; add a `blocked-on:` comment on the issue itself per `issue-tracking.md` Rule 2 |

Status updates are the **minimum** sync. Other fields (Iteration,
Quarter, Target date, Team) are optional — populate them when the
board owner has set those fields up for the scope and the
information is real, not guessed.

### gh recipe — flip status

The Status field is a `ProjectV2SingleSelectField`. You need three
IDs: the project ID, the field ID, and the option ID. For board 3
these are stable:

```
PROJECT_ID=PVT_kwDOAOaXws4BZkHw
STATUS_FIELD_ID=PVTSSF_lADOAOaXws4BZkHwzhUh54g
OPT_TODO=f75ad846
OPT_IN_PROGRESS=47fc9ee4
OPT_DONE=98236657
```

Re-discover with `gh project field-list 3 --owner noetl --format
json` if these change. Boards other than 3 need their own
discovery pass — the IDs are per-project.

Each item also has its own item ID (different from the issue
number). Look it up once:

```bash
ITEM_ID=$(gh project item-list 3 --owner noetl --format json \
  | jq -r '.items[] | select(.content.number == <ISSUE_NUMBER>) | .id')
```

Then flip:

```bash
gh project item-edit \
  --project-id "$PROJECT_ID" \
  --id "$ITEM_ID" \
  --field-id "$STATUS_FIELD_ID" \
  --single-select-option-id "$OPT_IN_PROGRESS"
```

## Rule 3 — every pointer bump checks the board

Parallel to `issue-tracking.md` Rule 1b (pointer bumps check the
open-issue list) and `wiki-maintenance.md` Rule 1b (pointer bumps
check the wiki). Before committing a `chore(sync): bump <repo>`:

1. For each `Closes noetl/ai-meta#NN` / `Refs noetl/ai-meta#NN`
   in the merged PR range, look up the issue's board status.
2. If the issue is now closed but its board status is still
   `In progress` or `Todo`, flip it to `Done` in the same change
   set as the pointer bump. (Most boards auto-move closed issues
   to Done via a workflow; verify rather than assume.)
3. If the bump promotes an issue from "queued" to "actively
   shipping" (first PR landing on a previously-Todo issue), flip
   that issue to `In progress`.
4. If the pointer bump cites an `ai-task` issue that ISN'T on the
   board, add it (Rule 1) before committing.

The `/bump-pointer` skill should walk this check alongside the
issue-list and wiki checks.

## Rule 4 — boards reflect today, not history

Boards are a present-tense view. Do NOT use them as an audit log
— that's what issue comments and `Sessions-Log.md` are for.
Concretely:

- Don't create board columns for old phases ("Phase 2.a shipped",
  "Phase 2.b shipped") — the issue itself carries the phase
  history.
- Don't add items for closed/archived work just to keep them
  visible. Closed issues stay on the board in the `Done` column
  for a short rolling window (the default board view filters them
  out anyway).
- The view URL in the registry (`/views/1`) is the working view
  the team looks at — keep it as the live state, not the
  everything-ever list.

If a board's `Done` column gets crowded enough to slow down
loading, archive items via `gh project item-archive` rather than
deleting them. Archive preserves the audit trail; delete loses it.

## Coordination with other rules

- [`issue-tracking.md`](issue-tracking.md) — the issue is the
  durable task; the board is the queryable view of it. Every
  rule there ("first touch", "update in same change set", "every
  pointer bump checks") has a board-side mirror in this file.
- [`wiki-maintenance.md`](wiki-maintenance.md) Rule 0a — the
  ai-meta wiki dashboard, the projects board, and the issue
  tracker are three views of the same state. Update them in the
  same change set.
- [`commit-conventions.md`](commit-conventions.md) — pointer-bump
  commit messages that move an issue across the board don't need
  a separate "roadmap board updated" line, but the bump body
  SHOULD say "+ roadmap board updated" when status moved (as in
  ai-meta@00300ad — "bump server to v2.1.5 + wiki + roadmap board
  updated"). That's the audit trail for the board edit.
- [`handoffs.md`](handoffs.md) — when a handoff round dispatches,
  the umbrella's board status moves to `In progress` if it wasn't
  already.

## When this rule doesn't fire

- Issues without the `ai-task` label (external bug reports,
  community contributions on submodule repos) stay off the
  ai-meta board. They may have their own board on the submodule
  side; that's owned by the submodule's maintenance, not by this
  rule.
- One-off chip-spawn tasks (`mcp__ccd_session__spawn_task`) that
  finish in a single session without opening an issue. No issue,
  no board item.
- Inline-bucket trivia (typo fixes, formatting, comment tweaks).
  No issue, no board item.

## History

Codified 2026-06-02 (evening) after standing instruction:

> add new rule to keep project roadmap updated ai-meta. We will
> keep more projects across repos in the future.

The registry shape (table at the top, scoped boards opted in by
adding a row) is designed so new boards — per-program, per-
customer, per-large-initiative — can be added without re-writing
the rule body.
