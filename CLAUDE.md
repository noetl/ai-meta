# Claude Code Entry Point

Read these files at session start (in order):

1. `AGENTS.md` — mandatory rules for this repo
2. `agents/rules/execution-model.md` — the foundational shape every
   feature, integration, and operational change must honor
3. `memory/current.md` — active working state
4. Latest entries in `memory/inbox/` — recent uncompacted work
5. **Open ai-task issues** — durable task store across sessions:
   ```bash
   gh issue list --repo noetl/ai-meta --state open --label ai-task --limit 30
   ```
   See `agents/rules/issue-tracking.md` for the convention.
6. **ai-meta wiki dashboard** at <https://github.com/noetl/ai-meta/wiki>
   — single pane of glass for the ecosystem (active umbrellas, repo
   map, releases, session log).  Local clone at
   `repos/ai-meta-wiki/`.  Update **in the same change set as
   substantive work** per `agents/rules/wiki-maintenance.md`
   Rule 0a — every new ai-task issue gets an `Umbrella-*` page,
   every pointer bump gets a Sessions-Log entry, every tagged
   release gets a Releases row.
7. `sync/issues/` — in-flight cross-repo tracking
8. `handoffs/active/` — in-flight cross-agent handoffs whose latest
   round is a prompt with no matching result yet, or whose latest
   result has status `partial` / `blocked` (see
   `handoffs/README.md` and `agents/rules/handoffs.md`)

## Project structure

```
agents/                          # SHARED (all agents)
  rules/                         #   modular rule files (auto-loaded via .claude/rules symlink)
  skills/                        #   workflow definitions (auto-loaded via .claude/skills symlink)
  profiles/                      #   per-agent behavioral profiles
.claude/
  settings.json                  #   Claude Code permissions, hooks, env
  rules -> ../agents/rules       #   symlink to shared rules
  skills -> ../agents/skills     #   symlink to shared skills
  agents/                        #   Claude-specific subagent definitions (frontmatter + @import)
.github/copilot-instructions.md  # Copilot entry point (references agents/)
.cursorrules                     # Cursor entry point (references agents/)
handoffs/                        # File-based cross-agent prompts + results
  active/                        #   in-flight threads (round-NN-prompt.md + round-NN-result.md)
  archive/                       #   closed threads
  templates/                     #   copyable prompt.md / result.md
memory/                          # Git-tracked shared memory
playbooks/                       # operational runbooks
scripts/                         # memory_add.sh, memory_compact.sh
sync/                            # cross-repo coordination notes
repos/                           # Git submodules (the actual codebases)
```

## Skills (slash commands)

- `/memory-add "<title>" "<summary>" "<tags>"` — create and commit a memory entry
- `/memory-compact` — compact inbox entries into a summary
- `/sync-note "<topic>"` — create a sync note from the template
- `/bump-pointer "<repo>"` — update a submodule pointer after upstream merge
- `/handoff-open <slug> "<description>"` — open a cross-agent handoff thread (dispatcher side)
- `/handoff-result <slug>` — scaffold the result file for the latest prompt in a thread (executor side)
- `/issue-open "<title>" "<repo>"` — open a tracked ai-task issue on noetl/ai-meta (see `agents/rules/issue-tracking.md`)
- `/issue-close <number>` — close a tracked ai-task issue with the landing PR / commit cited

## Quick commands (manual)

- Add memory: `./scripts/memory_add.sh "<title>" "<summary>" "<tags>"`
- Compact memory: `./scripts/memory_compact.sh`
- Replay Firestore MCP events: `./scripts/firestore_replay.sh events <thread_path> [--from N] [--to N] [--type-filter type1,type2]`
- Submodule status: `git submodule status --recursive`
- Bump pointer: `git submodule update --remote repos/<name> && git add repos/<name>`

## Commit conventions

- `memory(add): <topic>`
- `memory(compact): <scope>`
- `memory(curate): <scope>`
- `chore(sync): bump <repo> to <short-sha>`
- `docs(agents): <description>`
- `handoff(open): <slug>` — when writing `round-01-prompt.md`
- `handoff(prompt): <slug> round NN` — when writing a follow-up prompt
- `handoff(result): <slug> round NN` — when writing a result
- `handoff(close): <slug>` — when moving a thread to `handoffs/archive/`
