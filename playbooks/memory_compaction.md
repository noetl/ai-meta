# Playbook: AI Memory Compaction

## Objective

Keep AI memory usable over time by moving raw notes from inbox into compactions and updating current state.

## Steps

1. Add a focused memory entry with `./scripts/memory_add.sh`.
2. Review pending entries under `memory/inbox/`.
3. Run `./scripts/memory_compact.sh`.
4. Review updated files:
   - `memory/compactions/<timestamp>.md`
   - `memory/current.md`
   - `memory/timeline.md`
   - `memory/archive/...`
5. Commit with `memory(compact): <scope>`.

## Commit chain guidance

- Use `memory(add): <topic>` for raw entries.
- Use `memory(compact): <date/scope>` for compactions.
- Keep one logical memory update per commit.
