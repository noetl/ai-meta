# GitHub Copilot Instructions for ai-meta

You are operating in the `ai-meta` meta-repository for the NoETL ecosystem.

## Required Reading

Read these files at session start:

1. `AGENTS.md` — mandatory rules
2. `memory/current.md` — active working state
3. `agents/profiles/` — your working profile
4. `agents/rules/` — all rule files

## Rules

Read and follow all files in `agents/rules/`:

- `safety.md` — no secrets, no history rewriting, public repo
- `allowed-content.md` — what can be committed
- `submodules.md` — how to work with repos/*
- `commit-conventions.md` — commit message prefixes
- `memory-workflow.md` — how to add/compact memory
- `logging.md` — log hygiene for service repos
- `ops-deploy.md` — use ops playbooks for deployment

## Skills (workflows you can execute)

Read the SKILL.md in each directory under `agents/skills/`:

- `agents/skills/memory-add/` — create a memory inbox entry
- `agents/skills/memory-compact/` — compact inbox into summaries
- `agents/skills/sync-note/` — create a cross-repo sync note
- `agents/skills/bump-pointer/` — update submodule pointer

## Key Commands

- Add memory: `./scripts/memory_add.sh "<title>" "<summary>" "<tags>"`
- Compact memory: `./scripts/memory_compact.sh`
- Submodule status: `git submodule status --recursive`
