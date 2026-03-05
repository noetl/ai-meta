---
name: memory-compact
description: Compact inbox entries into a summary and update current.md
allowed-tools:
  - Bash
  - Read
---

# Compact Memory

Run the compaction script to consolidate inbox entries.

## Steps

1. Show how many inbox entries exist:
   ```
   find memory/inbox -name '*.md' | wc -l
   ```
2. If there are entries, run compaction:
   ```
   ./scripts/memory_compact.sh
   ```
3. Read the new compaction file and `memory/current.md` to confirm.
4. Stage and commit:
   ```
   git add memory
   git commit -m "memory(compact): <date or scope>"
   ```
5. Show the user a summary of what was compacted and ask if they want to push.
