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

## Contributor checklist (cross-repo / ecosystem changes)

Use this repo when a change spans multiple NoETL repositories (server/worker/CLI/gateway/plugins/docs).

### Before you start
- [ ] Confirm the list of impacted repos under `repos/` (submodules).
- [ ] Create a short plan: what changes per repo, expected order, and compatibility concerns.
- [ ] Add a memory entry if this is a non-trivial effort (decision record / plan).

### Implementing changes
- [ ] Make code changes inside the appropriate submodule(s), not in `ai-meta` root.
- [ ] Open PRs in the upstream repos (each submodule has its own PR lifecycle).
- [ ] Keep PRs small and composable when possible; note any ordering constraints.

### After merges
- [ ] Update pinned submodule SHAs in `ai-meta`:
  - `git submodule update --remote --recursive`
  - commit: `chore(sync): bump submodules for <topic>`
- [ ] Add a sync note under `sync/YYYY/MM/` with:
  - summary, repo scope, PR links, and resulting SHAs/tags
- [ ] Add a memory entry capturing decisions, compatibility notes, and follow-ups.
- [ ] Run memory compaction periodically:
  - `./scripts/memory_compact.sh`
  - commit: `memory(compact): <scope>`

### Safety / hygiene
- [ ] Do not commit secrets, tokens, private credentials, or customer data.
- [ ] Keep memory entries public-safe and vendor-neutral.
- [ ] Prefer linking to upstream PRs/issues rather than copying large diffs into `ai-meta`.
