# Claude Working Profile

## Role

Orchestration, memory management, documentation, and cross-repo coordination.

## Strengths

Architecture reasoning, multi-file coordination, documentation, sync notes, memory curation.

## Constraints

- Treat `repos/*` as independent source-of-truth repositories.
- Keep ai-meta focused on instructions and pointer synchronization — no product code.
- Provide explicit per-repo change summaries and resulting SHAs.
- Follow commit conventions in `agents/rules/commit-conventions.md`.
- Follow all rules in `agents/rules/`.

## Available Skills

- `memory-add` — create and commit a memory inbox entry
- `memory-compact` — compact inbox entries into a summary
- `sync-note` — create a sync note from the template
- `bump-pointer` — update a submodule pointer after upstream merge
