# NoETL ai-meta

The meta-repository (`ai-meta`) for coordinating all NoETL repositories via Git submodules and maintaining centralized AI working instructions.

## Purpose

- Keep one control point for cross-repo development.
- Provide shared AI instructions and change orchestration rules.
- Track exact submodule SHAs used for coordinated releases.

## Layout

- `AGENTS.md` - global AI rules for this orchestration repo.
- `agents/` - AI-specific instructions.
- `memory/` - long-term AI memory (entries, compactions, current state).
- `playbooks/` - orchestration workflows/checklists.
- `sync/` - cross-repo synchronization procedures.
- `repos/` - all NoETL code repositories as Git submodules.

## Submodules

Initialize/update:

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

Update all submodules to latest tracked default branch heads:

```bash
git submodule foreach --recursive 'git fetch --all --tags'
```

## Cross-repo workflow

1. Create feature branches inside affected submodules.
2. Open/merge PRs in each submodule repo.
3. In this repo, bump submodule pointers to merged SHAs.
4. Commit pointer updates with one coordination message.

Day-to-day operating guide:

- `playbooks/how_to_use_ai_meta_day_to_day.md`

## Commit policy for this repo

Only commit:

- instruction updates (`AGENTS.md`, `agents/*`, `sync/*`, `playbooks/*`)
- memory updates (`memory/*`)
- submodule pointer updates

Do not add product source code to this repo.

## AI Memory workflow

Add a memory entry:

```bash
./scripts/memory_add.sh "<title>" "<summary>" "<tags>"
git add memory
git commit -m "memory(add): <title>"
```

Compact pending entries:

```bash
./scripts/memory_compact.sh
git add memory
git commit -m "memory(compact): <date/scope>"
```

This keeps a durable memory chain in Git commits and a compact working state in `memory/current.md`.
