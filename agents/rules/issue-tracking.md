# Issue Tracking

Agent task-amnesia — losing track of pending follow-ups while
solving the immediate problem — is the single biggest source of
silently-dropped work across NoETL sessions. This rule fixes it by
making **noetl/ai-meta GitHub Issues** the durable task store.

In-session task lists (`TaskCreate` / `TaskUpdate`) die when the
session ends. Memory entries get compacted. The chip-spawn
mechanism opens a new session but doesn't track whether the spawned
work finished. Issues outlive all three.

## Where issues live

**Two-tier model** — umbrella issues in `noetl/ai-meta`, per-round
sub-issues in the owning submodule.

### Tier 1: ai-meta umbrella

`noetl/ai-meta` holds the **umbrella** issue for any task that
will outlive the current session. It captures the goal, the
acceptance criteria, the pointers, and the audit trail across
the whole task — including work that spans multiple submodules
and multiple rounds.

- Labels: `ai-task` + `repo:<primary-submodule>`.
- Surfaced by the session-start query
  (`gh issue list --repo noetl/ai-meta --label ai-task`).
- Closed manually with the citation comment described in
  "Closing the loop" below — typically after the final
  pointer-bump commit lands.

### Tier 2: submodule per-round sub-issues

When work on an umbrella issue is concrete enough to dispatch
as a PR — i.e. a handoff round is about to ship — open a
**sub-issue in the owning submodule repo** to track that
specific round's PR. One sub-issue per submodule per round.

- Labels: `ai-task` on the submodule repo (create it if
  missing; same `#fbca04` colour as the ai-meta label).
- Title format: `<umbrella-title> — Round NN (<phase letter
  range>)`. Example:
  `Remove direct Firestore queries — Round 02 (Phase B: SPA cutover)`.
- Body links **up** to the ai-meta umbrella
  (`Tracks noetl/ai-meta#NN`) and lists the phase numbers
  this round covers.
- Closed by the submodule PR via the standard GitHub
  `Closes <repo>#<NN>` keyword in the PR body, so it
  auto-closes on merge.
- The ai-meta umbrella gets a comment citing the new
  sub-issue + the PR URL when the round opens. The umbrella
  stays open until every planned round has shipped.

### When a round spans multiple submodules

A single round that touches multiple submodules opens **one
sub-issue per submodule** with shared title prefix + per-repo
suffix. Example: Round 3 of the Firestore-removal work would
open `noetl/travel#NN — Round 03 (Phase C: SPA gatewaySubscriptions cleanup)`,
`noetl/gateway#NN — Round 03 (Phase C: /api/subscriptions/firestore removal)`,
and `noetl/ops#NN — Round 03 (Phase C: drop Firestore helm config)` —
each PR closes its own sub-issue; the ai-meta umbrella closes
after the last pointer bumps.

### External bug reports

Issues filed against a submodule by community contributors
(`noetl/cli#123` opened by an outsider) stay where they are
under their own labels. The `ai-task` label is for work agents
opened or own — don't backfill external issues with `ai-task`.

## Labels

| Label | Meaning |
|---|---|
| `ai-task` | Issue is tracked by AI agents; surfaced at session start by the standard query. Always apply. |
| `repo:<name>` | Pointer to the submodule the work lives in (`repo:cli`, `repo:gateway`, `repo:noetl`, `repo:ops`, `repo:docs`, `repo:travel`, `repo:doctor`, `repo:e2e`, `repo:gui`, `repo:apt`, `repo:ai-meta`). Always apply, even when the work spans multiple repos — pick the primary one. |
| `bug` / `enhancement` / `documentation` | Existing GitHub-default labels. Apply when they fit; don't invent new ones. |

Avoid label sprawl. Status (open / closed) lives on the issue, not
in a label. "Blocked" lives in the issue body — write what it's
blocked on so the next reader knows.

## When to open an issue

Three buckets, applied in order:

1. **Inline** — finish it in this turn. A typo fix, a one-line
   doc tweak, a missing comma. No tracking overhead.
2. **Chip-spawn** (`mcp__ccd_session__spawn_task`) — a one-shot
   side task this session can dispatch to a fresh worktree
   *right now*. Use when the work is small, well-scoped, and the
   user is online to accept the chip. Chip-spawn does **not**
   replace an issue — if the chipped task is non-trivial or
   might fail, also open an issue (or have the spawned session
   open one as its first act).
3. **Issue** — anything that will outlive this session.
   Specifically:
   - Work that needs a future session to pick up.
   - Work blocked on a human decision, external action, or
     another PR landing.
   - Cross-agent coordination where Codex / Cursor / Claude
     might each pick up a slice.
   - Anything the user might reasonably ask "what's the status
     of X?" three days from now.

When in doubt, open the issue. The cost is one `gh` command; the
benefit is the task surviving the next compaction.

## Rule 1 — open an issue on first touch of substantive work

Parallel to [`wiki-maintenance.md`](wiki-maintenance.md) Rule 1
("deep-dive docs on first touch"). When development work changes a
public surface of a submodule and no tracking issue yet exists, open
one **before** opening the PR.

"Substantive" means the change is at least one of:

- New behavior (added command, endpoint, env var, schema field).
- Behavior change (renamed, removed, default flipped, error
  taxonomy moved).
- Bug fix that the team would want to find later by searching
  ("the Auth0 dashboard URL fix").
- Anything that needs a wiki update under `wiki-maintenance.md`
  Rule 1 or Rule 2.

Cosmetic refactors, lint fixes, formatting, dependency bumps that
don't change behavior — **inline** bucket, no issue.

The first PR commit that lands the substantive change MUST cite
the issue in the PR body (`See noetl/ai-meta#NN` or
`Closes noetl/ai-meta#NN` if the PR fully satisfies the goal). If
the PR is opened first by mistake, open the issue and amend the
PR description before requesting review.

## Rule 2 — update the issue in the same change set as the code

Parallel to `wiki-maintenance.md` Rule 2 ("validate the wiki
against code changes"). When the work on an existing issue moves
forward, the issue is touched in the **same change set** as the
code:

1. **Picking it up** — leave a comment:
   `Starting work in session <YYYY-MM-DD>. Branch: <name>.`
2. **PR opened** — comment with the PR URL. If the goal needs to
   shift, edit the `## Goal` section in the issue body to match
   (append-only is the rule for status; goals legitimately move
   as understanding sharpens).
3. **PR merged, awaiting pointer bump** — comment:
   `Merged via <submodule>#<NN>. Awaiting ai-meta pointer bump.`
4. **Pointer bumped** — close the issue (see Closing the loop
   below).

Multi-PR work is the same shape, just with multiple step-2 / step-3
comments. The issue is the audit trail; the comments are the
heartbeat.

Sub-PR commits inside the same submodule do not each need their
own comment — one comment per PR is sufficient. But cross-submodule
work (e.g. gateway PR + cli PR + helm PR all serving one issue)
should each get a comment when they merge so the closing comment
can cite the full set.

## Rule 1b — every pointer bump checks the open-issue list

Parallel to `wiki-maintenance.md` Rule 1b ("every pointer bump
checks the wiki"). Before committing a `chore(sync): bump <repo>`:

1. Read the submodule's `git log` since the previous pointer
   value — that's the code being landed.
2. For each merged PR in that range, check whether an ai-task
   issue tracks it.
3. If yes, update the issue per Rule 2 (comment with the merging
   PR + this pointer-bump commit); close if the issue's `## Goal`
   is now satisfied.
4. If no, decide:
   - **Substantive surface change with no issue** — open one
     retroactively per Rule 1, citing the merged PR as the
     reason, and add the pointer-bump SHA as the closing
     comment. (Yes, you open it just to close it. The audit
     trail is the point.)
   - **Trivial / housekeeping** — no issue needed.

This is the same dual-rail check the wiki rule applies: a pointer
bump touches both the wiki AND the issue tracker in the same
change set.

## Coordination with wiki-maintenance

A substantive change typically produces three artifacts at the
same time:

1. **Code change** — a PR in the owning submodule.
2. **Wiki update** — page(s) in the matching wiki (per
   `wiki-maintenance.md`).
3. **Issue trail** — the ai-task issue tracking the work
   (per this rule).

The right shape:

- Issue body links the wiki page(s) it will produce or update.
- Wiki page (if substantive enough to warrant a "see also")
  links the issue.
- PR body cites the issue (`Closes noetl/ai-meta#NN`).
- ai-meta pointer-bump commit message cites the issue (`Closes
  noetl/ai-meta#NN`) so the ai-meta `git log` is a usable index.

The three artifacts ride the same change set. Don't land any one
of them and defer the others — that's how drift compounds.

## What to open an issue for, vs. a handoff

Issues and handoffs (`handoffs/active/<slug>/`) are complementary:

- **Issue** = "this work exists; here's the goal; here's status."
  Lightweight, append-only via comments, queryable.
- **Handoff** = "dispatcher → executor brief for *one specific
  round* of work on a task." Heavyweight, structured, gated.

For most ai-tasks, an issue alone is enough. Open a handoff thread
only when the next step is a cross-agent dispatch with destructive
phases, file-level coordination, or a specific result file the
dispatcher will diff. Handoffs reference their issue in the
frontmatter (`tracks: noetl/ai-meta#NN`); issues link the handoff
back in a comment.

## Issue body conventions

Title: imperative action phrase, under 70 chars. "Fix CLI Auth0
dashboard URL to include region segment", not "Auth0 dashboard URL
bug". Treat it like a commit message — readers should know what
"closed" means without opening the issue.

Body, in this order:

1. **Context** — one paragraph. What surfaced this? Include
   session date or PR link so the reader can find the
   conversation that produced it.
2. **Goal / acceptance** — bulleted list. Concrete enough that a
   different agent could pick it up cold.
3. **Pointers** — file paths with line numbers, command output
   excerpts, error fingerprints. Same standard as handoff
   prompts: a fresh agent must be able to act without re-deriving
   context.
4. **Blocked on / depends on** — explicit cross-references. Use
   GitHub's auto-link syntax (`noetl/cli#13`,
   `noetl/ai-meta#42`).
5. **Status updates** — append as comments, never edit the body
   to rewrite history. Update the body only to keep the goal /
   pointers section current.

Public-repo discipline applies (`agents/rules/safety.md`): no
tokens, no credentials, no customer data. If a fingerprint string
contains a secret, mask it before pasting.

## Session-start discovery

`CLAUDE.md` lists the open-issue query in the session-start read
list. The standard incantation is:

```bash
gh issue list --repo noetl/ai-meta --state open --label ai-task --limit 30
```

Read the titles; open the ones that intersect what the user just
asked for. The SessionStart hook surfaces the open count alongside
the memory inbox count so it's visible from the first turn.

## Opening an issue (manual recipe)

```bash
gh issue create --repo noetl/ai-meta \
  --title "Fix CLI Auth0 dashboard URL to include region segment" \
  --label ai-task --label repo:cli \
  --body "$(cat <<'EOF'
## Context

Surfaced 2026-05-27 during noetl/cli wiki update.  Auth0 PKCE
pre-flight prints a broken dashboard URL when the tenant domain
follows the regional shape ``<tenant>.<region>.auth0.com``.

## Goal

Update ``extract_auth0_tenant_from_domain`` (or replace with a
helper that returns both tenant and region) so the dashboard URL
matches Auth0's actual format:

  https://manage.auth0.com/dashboard/<region>/<tenant>/applications/<client_id>/settings

Apply the fix at both call sites:

- ``repos/cli/src/main.rs:3540`` (timeout hint in ``wait_for_pkce_callback_with_hint``)
- ``repos/cli/src/main.rs:3731`` (pre-flight notice in ``auth0_pkce_authorize``)

Add unit tests for both formats (``acme.auth0.com`` no region;
``mestumre-development.us.auth0.com`` with region).

Update wiki page ``auth-login.md`` if the example URL format
needs to change.

## Pointers

- Helper: ``repos/cli/src/main.rs:3486``
- Bug report: user terminal output 2026-05-27, "should I export
  token or what should I do" turn.
EOF
)"
```

The agent SHOULD use `/issue-open` (see below) rather than typing
this by hand.

## Closing the loop

When the work lands:

1. The submodule PR body cites the issue
   (`See noetl/ai-meta#42`).
2. After the submodule PR merges, bump the pointer in ai-meta as
   normal.
3. **Manually close the ai-meta issue** with a comment that
   references the merging PR and the pointer-bump commit:

```bash
gh issue close NN --repo noetl/ai-meta --comment "Landed via noetl/cli#17 + ai-meta@dc20e51."
```

Closing the issue is the only way it leaves the session-start
query. Don't skip it — a stale "ai-task" inbox is worse than no
inbox.

## What this rule does NOT do

- It does not replace `memory/current.md`. Memory captures
  *platform state* and *session-level summaries*; issues capture
  *open work items*. They overlap but don't substitute.
- It does not replace handoffs. Handoffs are dispatch briefs;
  issues are the task list. A task can have zero, one, or many
  handoff rounds against it.
- It does not require every chip-spawn to also open an issue.
  Chip-spawn for small, scoped, immediately-dispatched work
  stays as-is.

## Related

- [`commit-conventions.md`](commit-conventions.md) — commit
  message prefixes (no new `issue(open):` prefix needed; issues
  aren't committed).
- [`handoffs.md`](handoffs.md) — when to escalate from issue to
  handoff thread.
- [`roadmap-boards.md`](roadmap-boards.md) — every ai-task issue
  also lives on a GitHub Projects v2 board; status sync is part
  of the same change set as the issue update.
- [`safety.md`](safety.md) — public-repo discipline applies to
  issue bodies and comments.
