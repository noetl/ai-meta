---
name: sync-note
description: Create a sync note from the template for a cross-repo change
argument-hint: "<topic>"
allowed-tools:
  - Bash
  - Read
  - Write
---

# Create Sync Note

Create a new sync note under `sync/issues/` from the standard template.

## Steps

1. Read `sync/TEMPLATE.md` for the structure.
2. Ask the user for:
   - Which repos were involved
   - PR links (if any)
   - Resulting SHAs
   - Follow-up actions
3. Create the file at:
   ```
   sync/issues/YYYY-MM-DD-<topic-slug>.md
   ```
   Use today's date and a slug derived from `$ARGUMENTS`.
4. Fill in the template sections with the user's answers.
5. Stage and commit:
   ```
   git add sync/issues/
   git commit -m "chore(sync): add sync note for <topic>"
   ```
6. Ask if they want to push.
