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

**One inbox: `noetl/ai-meta`**, regardless of which submodule the
work eventually lands in.

- Submodule-internal work (e.g. "fix bug in CLI port-forward",
  "add gateway runtime-contract field") is still tracked as an
  ai-meta issue with a `repo:<submodule>` pointer label.
- Reason: the agent doing the work reads one inbox at session
  start, not eleven.
- The actual code change still goes through a PR in the owning
  submodule. The submodule PR's body references the ai-meta issue
  (`See noetl/ai-meta#NN`). The issue is closed manually after the
  submodule PR merges and the pointer bumps in ai-meta — issues do
  not auto-close from submodule PRs.

External bug reports filed against a submodule (`noetl/cli#123`
opened by a community contributor) stay where they are. The agent
inbox is for work the agent surfaced or owns.

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
- [`safety.md`](safety.md) — public-repo discipline applies to
  issue bodies and comments.
