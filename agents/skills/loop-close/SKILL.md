---
name: loop-close
description: Record a loop's outcome and archive it. Requires an outcome status, and a linked issue/handoff if the loop escalated.
argument-hint: "<slug>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
---

# Close a Loop

Record what happened and move a completed loop out of `active/` so the
working set stays current.

Behavioral rules: `agents/rules/loop-engineering.md`.

## Steps

1. Parse `$ARGUMENTS` as `<slug>`. Confirm `loops/active/<slug>/loop.md`
   exists. If not, abort and tell the user to check the slug.
2. Read the loop file. Confirm the Iterations section has at least one
   entry; if the loop closed with zero iterations attempted, note that
   explicitly rather than silently archiving an empty run.
3. Ask the user (or determine from the recorded iterations) the outcome
   status: `converged` (success condition met), `stopped-at-bound` (hit a
   hard bound without success), or `escalated` (handed off to a tracked
   issue or handoff thread).
4. Edit the file's `## Outcome` section with:
   - Status (one of the three above).
   - Iterations run.
   - Final result summary.
   - If `escalated`: the linked issue or handoff thread path. Required —
     do not proceed to archive without this link.
5. `mkdir -p loops/archive/<slug>/` and move the file:
   ```
   git mv loops/active/<slug>/loop.md loops/archive/<slug>/loop.md
   ```
   (Use `mv` + `git add`/`git rm` if the directory has other files.)
6. Stage and commit:
   ```
   git commit -m "loop(close): <slug>"
   ```
7. Print the archived path and outcome summary. Ask if the user wants to
   push.

## Hard constraints

- Never archive a loop without a recorded `## Outcome` status.
- Never archive an `escalated` loop without a linked issue or handoff path.
- Never overwrite a loop file that already exists at the archive
  destination — open a fresh slug instead if this one was somehow already
  closed.
