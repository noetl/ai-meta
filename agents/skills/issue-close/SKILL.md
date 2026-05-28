---
name: issue-close
description: Close a tracked ai-task issue on noetl/ai-meta with the landing PR / pointer-bump cited so the trail is auditable.
argument-hint: "<number>"
allowed-tools:
  - Bash
  - Read
---

# Close an ai-task Issue

Close an ai-task issue once the work has actually landed. The
close comment cites the landing PR and the pointer-bump commit so
a future reader can reconstruct what closed it.

Full convention: `agents/rules/issue-tracking.md`.

## Steps

1. Parse `$ARGUMENTS` as `<number>` (the ai-meta issue number,
   e.g. `42`). Reject non-numeric input.
2. Fetch the issue body so the agent can confirm acceptance:

   ```bash
   gh issue view <number> --repo noetl/ai-meta
   ```

   Read the `## Goal` section. **Confirm every bullet is
   actually satisfied.** If even one isn't, abort and tell the
   user which bullet is still open — don't close prematurely.
3. Identify the landing artifact(s). Typically one or both of:
   - A merged PR in a submodule (e.g. `noetl/cli#17`).
   - A pointer-bump commit on ai-meta `main` (e.g.
     `ai-meta@dc20e51`).
4. Close with a citation comment:

   ```bash
   gh issue close <number> --repo noetl/ai-meta \
     --comment "Landed via <submodule>#<PR> + ai-meta@<sha>."
   ```

   If the work spanned multiple PRs, list them:

   ```
   Landed via noetl/cli#13, noetl/cli#14, noetl/cli#16,
   noetl/cli#17 + ai-meta@dc20e51.
   ```

5. Print the closed issue URL.

## Hard constraints

- Don't close on intent alone. The work must be merged AND the
  pointer bumped (if the change requires one). "PR opened, awaiting
  review" is not a close — that's a comment update.
- Don't `--reopen` an issue from this skill. If the work
  regressed, open a new issue that links back to the original.
- Don't close someone else's issue without an explicit user
  go-ahead — ai-task issues opened by humans live by human rules.
- The citation comment is required. Closing silently breaks the
  audit trail.
