# Claude Code Entry Point

Read these files at session start (in order):

1. `AGENTS.md` — mandatory rules for this repo
2. `memory/current.md` — active working state
3. Latest entries in `memory/inbox/` — recent uncompacted work
4. `sync/issues/` — in-flight cross-repo tracking

## Project structure

```
.claude/
  settings.json          # permissions, hooks, env
  rules/                 # modular rules (auto-loaded by Claude Code)
  skills/                # slash commands: /memory-add, /memory-compact, /sync-note, /bump-pointer
  agents/                # subagent definitions: claude, codex
agents/                  # legacy profiles (kept for non-Claude agents)
memory/                  # Git-tracked shared memory
playbooks/               # operational runbooks
scripts/                 # memory_add.sh, memory_compact.sh
sync/                    # cross-repo coordination notes
repos/                   # Git submodules (the actual codebases)
```

## Skills (slash commands)

- `/memory-add "<title>" "<summary>" "<tags>"` — create and commit a memory entry
- `/memory-compact` — compact inbox entries into a summary
- `/sync-note "<topic>"` — create a sync note from the template
- `/bump-pointer "<repo>"` — update a submodule pointer after upstream merge

## Quick commands (manual)

- Add memory: `./scripts/memory_add.sh "<title>" "<summary>" "<tags>"`
- Compact memory: `./scripts/memory_compact.sh`
- Submodule status: `git submodule status --recursive`
- Bump pointer: `git submodule update --remote repos/<name> && git add repos/<name>`

## Commit conventions

- `memory(add): <topic>`
- `memory(compact): <scope>`
- `memory(curate): <scope>`
- `chore(sync): bump <repo> to <short-sha>`
- `docs(agents): <description>`
