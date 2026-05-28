---
name: issue-open
description: Open a tracked ai-task issue on noetl/ai-meta. Use this when work will outlive the current session (cross-session task, blocked on external action, needs another agent later).
argument-hint: "\"<title>\" <repo>"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Open an ai-task Issue

Open a GitHub issue on `noetl/ai-meta` so the work survives session
compaction and is visible to every agent that picks up next.

Full convention: `agents/rules/issue-tracking.md`.

## When to use

The threshold is: **the work will outlive this session.** Open an
issue if any of these are true:

- A future session needs to pick it up.
- Blocked on a human decision, external action, or another PR
  landing.
- Cross-agent (Codex / Cursor / Claude all might touch it).
- The user might reasonably ask "what's the status of X" three
  days from now.

If the work is a one-shot side task this session can dispatch right
now, use `mcp__ccd_session__spawn_task` (chip-spawn) instead. If
it's a fix the agent will land in the next two tool calls, just do
it inline.

## Steps

1. Parse `$ARGUMENTS` as `"<title>" <repo>`. The repo arg is one of
   the submodule pointer-label values:
   `noetl | cli | gateway | ops | docs | travel | doctor | e2e | gui | apt | ai-meta`.
   Reject any other value.
2. Title must be an imperative action phrase under 70 chars (the
   shape of a commit message subject). Example: "Fix CLI Auth0
   dashboard URL to include region segment". Reject titles that
   are vague nouns ("Auth0 bug") or end with a question mark.
3. **Draft the body in conversation with the user** before opening
   the issue. The body MUST contain these four H2 sections:
   - `## Context` — one paragraph. What surfaced this? Cite the
     session date, the PR / commit that produced it, or the user
     turn that flagged it.
   - `## Goal` — concrete acceptance bullets. Specific enough that
     a fresh agent could act on them cold.
   - `## Pointers` — file paths with line numbers, command output
     excerpts, error fingerprints. Same standard as a handoff
     prompt.
   - `## Blocked on` — bullets with GitHub auto-link refs
     (`noetl/cli#13`, `noetl/ai-meta#42`). Use `(none)` if not
     blocked on anything.
4. Public-safety check: scan the drafted body for secrets, tokens,
   customer data. Mask any sensitive value before opening.
5. Open the issue:

   ```bash
   gh issue create --repo noetl/ai-meta \
     --title "<title>" \
     --label ai-task --label repo:<repo> \
     --body "$(cat <<'EOF'
   ## Context
   ...

   ## Goal
   - ...

   ## Pointers
   - ...

   ## Blocked on
   - (none)
   EOF
   )"
   ```

6. Print the issue URL the `gh` command returned, so the user (and
   any spawned session) can reference it.

7. If the issue was opened in response to a chip-spawn the agent
   just created, edit the chip's tldr / body to cite the issue
   number — the spawned session should know the issue exists.

## Hard constraints

- Repo label must be one of the known `repo:<submodule>` set.
  Don't create new pointer labels in this skill.
- Don't open duplicate issues. Run
  `gh issue list --repo noetl/ai-meta --state open --label ai-task --search "<keyword>"`
  first; if a matching open issue exists, comment on it instead
  ("Surfaced again in <session-date>: <new context>") and skip
  the create.
- Don't auto-close someone else's issue from this skill. Use
  `/issue-close` (and only when the work has actually landed).
- Body must contain all four required H2 sections. A skeleton
  with `## Goal\n- TBD` is fine while drafting, but the issue
  shouldn't be opened with sections missing.
- Never include secrets. The repo is public.
