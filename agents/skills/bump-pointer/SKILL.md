---
name: bump-pointer
status: active
description: Update a submodule pointer after upstream merge.  Implements wiki-maintenance Rule 1b + issue-tracking Rule 1b — the bump touches the wiki AND the ai-task issue list in the same change set.
argument-hint: "<repo-name>"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
---

# Bump Submodule Pointer

Update a submodule to its latest remote commit and commit the
pointer change. The bump is the natural checkpoint where three
trails are reconciled in lockstep:

1. **Code** — the submodule pointer itself.
2. **Wiki** — `agents/rules/wiki-maintenance.md` Rule 1b ("every
   pointer bump checks the wiki").
3. **Issue trail** — `agents/rules/issue-tracking.md` Rule 1b
   ("every pointer bump checks the open-issue list").

Skipping any of (2) or (3) is how drift compounds. Don't ship a
pointer bump that only updates the code.

## Steps

1. **Sync first.** Pull latest ai-meta:
   ```bash
   git pull --ff-only
   ```

2. **Update the submodule pointer.**
   ```bash
   git submodule update --remote repos/$ARGUMENTS
   ```

3. **Inspect what's landing.** Capture the SHA range so steps 5 +
   6 + 7 can query against it:
   ```bash
   OLD_SHA=$(git ls-tree HEAD repos/$ARGUMENTS | awk '{print $3}')
   NEW_SHA=$(cd repos/$ARGUMENTS && git rev-parse HEAD)
   (cd repos/$ARGUMENTS && git log --oneline $OLD_SHA..$NEW_SHA)
   ```
   Show the user the SHA pair and the commit summaries. If the
   range is empty, abort — there's nothing to bump.

4. **Identify merged PRs in the range.** PR numbers appear in
   merge-commit subjects (`Merge pull request #NN from …`):
   ```bash
   (cd repos/$ARGUMENTS && git log --merges --oneline $OLD_SHA..$NEW_SHA)
   ```
   List them. The next two steps loop over this list.

5. **Wiki check (`wiki-maintenance.md` Rule 1b).** For each
   merged PR in the range:
   - Identify the wiki that owns this submodule (see
     `agents/rules/wiki-maintenance.md`'s "Rule 1b" table).
   - Determine whether the merged code changed a public surface
     the wiki documents.
   - If yes, the wiki update lands in the same change set as
     this pointer bump (open the wiki repo, edit the page,
     commit + push, bump the wiki submodule pointer too).
   - If no covered page exists yet, follow Rule 1 and add one.

6. **Issue check (`issue-tracking.md` Rule 1b).** For each
   merged PR in the range:
   ```bash
   gh issue list --repo noetl/ai-meta --state open --label ai-task \
     --search "$ARGUMENTS#<PR-NUMBER>"
   ```
   - If an open ai-task issue tracks the PR, leave a comment
     citing the merging PR and the pointer-bump commit you're
     about to write. Close the issue if its `## Goal` bullets
     are satisfied.
   - If no issue tracks it, decide:
     - **Substantive surface change** — open one retroactively
       via `/issue-open`, then immediately close it with the
       pointer-bump commit as the citation. The audit trail is
       the point.
     - **Trivial / housekeeping** — no issue needed; note
       "trivial: <reason>" in the bump commit body so the
       reviewer can see you considered it.

7. **Commit the pointer bump.** Cite the issue(s) and the wiki
   commit in the body so `git log` is a usable index:
   ```bash
   git add repos/$ARGUMENTS
   git -c commit.gpgsign=false commit -m "$(cat <<EOF
   chore(sync): bump $ARGUMENTS to <short-new-sha>

   Lands <submodule>#<PR>, <submodule>#<PR>, …

   Wiki: updated <page> in repos/<wiki-submodule> (commit <wiki-sha>).
   Issues: closes noetl/ai-meta#<NN>, noetl/ai-meta#<NN>.
   EOF
   )"
   ```

   If both wiki and issue checks turned up nothing relevant,
   say so explicitly:
   ```
   Wiki: no surface change requiring a doc update.
   Issues: trivial pointer bump, no ai-task issue needed.
   ```

8. **Ask the user before pushing.** Pointer bumps are routine,
   but they're also the artifact that touches the most
   stakeholders, so confirm before `git push origin main`.

## Hard constraints

- Never bump a pointer past code that has open `ai-task` issues
  with `## Goal` bullets that the new SHA doesn't satisfy.
  Update the issue first; bump second.
- Never skip the wiki check, even if "I'll do it after." That's
  the drift this rule exists to prevent.
- Never push to `origin/main` without explicit user go-ahead.
- Never bump and leave the wiki for a follow-up commit. They
  ride together; that's the whole rule.
