---
name: memory-add
description: Create a new memory inbox entry and commit it
argument-hint: "<title>" "<summary>" "<tags>"
allowed-tools:
  - Bash
  - Read
---

# Add Memory Entry

Create a memory entry from the provided arguments and commit it.

## Steps

1. Run from the ai-meta root:
   ```
   ./scripts/memory_add.sh $ARGUMENTS
   ```
2. Read the created file to confirm it looks correct.
3. Stage and commit:
   ```
   git add memory/inbox
   git commit -m "memory(add): $1"
   ```
4. Show the user the created file path and ask if they want to push.
