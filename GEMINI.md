# Gemini CLI Entry Point

Read these files at session start (in order):

1. `AGENTS.md` — mandatory rules for this repo
2. `agents/README.md` — agent mapping and shared source-of-truth layout
3. `agents/rules/execution-model.md` — foundational architecture boundary
4. `memory/current.md` — active working state
5. Latest entries in `memory/inbox/` — recent uncompacted work
6. Open ai-task issues:
   ```bash
   gh issue list --repo noetl/ai-meta --state open --label ai-task --limit 30
   ```
7. ai-meta wiki dashboard at <https://github.com/noetl/ai-meta/wiki>,
   especially `Home.md`, `Sessions-Log.md`, `Releases.md`, and matching
   `Umbrella-*.md` pages when wiki state is touched
8. `sync/issues/` — in-flight cross-repo tracking
9. `handoffs/active/` — in-flight cross-agent handoffs

## Project structure

```
agents/                          # SHARED (all agents)
  README.md                      #   agent mapping and adapter explanation
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
3. Read `agents/README.md` to understand which files are shared and which are tool adapters.
4. Follow the execution-model boundary before architecture, integration, deployment, or operational changes.
5. Keep ai-task issues and wiki pages aligned when work touches those surfaces.
6. Follow all rules in `AGENTS.md` and `agents/rules/*.md`.
7. Use `scripts/memory_add.sh` to record significant decisions or progress.
