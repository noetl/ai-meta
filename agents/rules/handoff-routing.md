# Handoff Routing — when to dispatch Codex vs do it yourself

This rule sits beside [`handoffs.md`](handoffs.md) (the file-based
cross-agent convention) and refines **who** picks up the work.
Handoffs.md says how to write the brief; this file says when
NOT to write a brief at all.

## The rule

**Claude writes Rust code directly.  Do not dispatch Codex for
Rust changes inside any submodule.**

The Rust submodules are:

- `repos/cli` (workspace: CLI + `noetl-executor`)
- `repos/server` (the `noetl-server` binary + service layer)
- `repos/worker` (the `noetl-worker` binary + tool dispatch)
- `repos/tools` (the `noetl-tools` registry crate)
- `repos/doctor` (the `noetl-doctor` diagnostic CLI)
- `repos/gateway` (the `noetl-gateway` HTTP edge)

When work in any of these repos requires a Rust code change,
Claude reads the relevant files via `Read`, edits via `Edit` /
`Write`, builds + tests via `Bash`, opens the PR via `gh`, and
runs the kind-validation cycle directly.  No Codex handoff
prompt, no Agent dispatch, no `handoffs/active/<slug>/` thread.

## Why

Codified 2026-06-08 after standing instruction:

> stop using codex for rust code - do it yourself

The session that day shipped 7 Codex Rust handoffs back-to-back
(#70, #71, #73 gap 1, #73 gap 2, #74, #72, #75) and the user
explicitly cut that pattern.  Reading the diff before merge,
reasoning about edge cases in-context, and producing the change
end-to-end keeps Claude in the loop on what shipped — which the
delegated pattern was eroding.

## When Codex IS still appropriate

The cut is specifically Rust code.  Other dispatch shapes stay
on the table:

- **Codex on non-Rust work** — Python, YAML, shell, documentation
  inside non-Rust submodules (e.g. `repos/noetl`, `repos/ops`,
  `repos/e2e`, the wiki repos).  These were historically rare;
  keep them rare.
- **Codex on Rust survey / triage only** — e.g. "produce a
  report of every call site of X across submodules" without
  changing code.  Still rare; prefer doing it inline.
- **General-purpose agents on read-only research** — fine for
  multi-file searches, cross-repo greps, broad surveys.  These
  return text reports, not commits.
- **Other specialized agents** — `claude-code-guide` for Claude
  Code questions; `code-reviewer` for review-only passes; etc.

## How this affects the workflow

The pattern that ran today was:

1. Identify the bug / feature.
2. Author a handoff prompt under `handoffs/active/<slug>/round-01-prompt.md`.
3. Dispatch a Codex Agent in the background.
4. Wait for completion notification.
5. Ask the user `ship it`.
6. Push the branch, open the PR.
7. Wait for merge.
8. Kind-validate, bump pointer, update wiki.

Steps 2-4 disappear under this rule.  The new flow is:

1. Identify the bug / feature.
2. Survey the code directly (`Read` + `Grep`).
3. Edit the files (`Edit` / `Write`).
4. Run local tests + build + clippy via `Bash`.
5. Open the PR (no `ship it` gate needed when Claude is the author
   — the user can review the PR description before merge).
6. Wait for merge.
7. Kind-validate, bump pointer, update wiki.

Steps 5b (ship-it gate) becomes optional when the change is
small + scoped.  For larger / more invasive Rust changes Claude
should still pause and confirm with the user before opening the
PR — same threshold as before, just without the Codex round-trip
in the middle.

## Coordination with other rules

- [`handoffs.md`](handoffs.md) — still applies for non-Codex
  cross-agent dispatch (Cursor, Gemini, etc.) and for human-to-human
  threads.  Rust-Codex specifically is what this rule excludes.
- [`rust-analyzer.md`](rust-analyzer.md) — the linked-projects
  config means Claude can navigate cross-submodule Rust changes
  in one VS Code session.  No structural reason to delegate.
- [`commit-conventions.md`](commit-conventions.md) — Claude-authored
  PR bodies stop citing `handoffs/active/...` as the authoring
  thread when there isn't one.

## When this rule doesn't fire

- Work that genuinely needs another physical worktree (e.g.
  worktree-isolated migrations across many files in parallel) —
  but that's an Agent + `isolation: "worktree"` use case, not a
  Codex handoff.  Rare.
- The user explicitly asks to dispatch Codex anyway (overrides
  this rule).
