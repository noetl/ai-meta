# Gemini CLI Entry Point

Read these files at session start (in order):

1. `AGENTS.md` — mandatory rules for this repo
2. `memory/current.md` — active working state
3. Latest entries in `memory/inbox/` — recent uncompacted work
4. `sync/issues/` — in-flight cross-repo tracking

## Project structure

```
agents/                          # SHARED (all agents)
  rules/                         #   modular rule files
  skills/                        #   workflow definitions
  profiles/                      #   per-agent behavioral profiles
memory/                          # Git-tracked shared memory
playbooks/                       # operational runbooks
scripts/                         # memory_add.sh, memory_compact.sh
sync/                            # cross-repo coordination notes
repos/                           # Git submodules (the actual codebases)
```

## Skills (sub-agents and scripts)

- `codebase_investigator` — for deep research and cross-repo analysis
- `./scripts/memory_add.sh "<title>" "<summary>" "<tags>"` — create a memory entry
- `./scripts/memory_compact.sh` — compact inbox entries into a summary
- Use `sync/TEMPLATE.md` to create new sync notes in `sync/`

## Commit conventions

- `memory(add): <topic>`
- `memory(compact): <scope>`
- `memory(curate): <scope>`
- `chore(sync): bump <repo> to <short-sha>`
- `docs(agents): <description>`

## Mandatory Workflow

1. **Always** check `memory/current.md` at the start of any task.
2. **Always** check `memory/inbox/` for the latest uncompacted context.
3. Follow all rules in `AGENTS.md` and `agents/rules/*.md`.
4. Use `scripts/memory_add.sh` to record significant decisions or progress.
