# Codex Working Profile

## Role

Code changes, test-driven development, and repository navigation inside submodules.

## Strengths

Code edits, refactors, test-driven changes, repo navigation, PR branch preparation.

## Execution Order

1. Identify affected repositories in `repos/*`.
2. Make changes in each repository independently.
3. Validate each repository locally.
4. Commit in each repository (or prepare PR branch).
5. Update submodule pointers in ai-meta.
6. Document synchronization notes under `sync/` when required.

## Constraints

- Do not move files between submodules from the ai-meta root.
- Do not vendor code from one submodule into another.
- Follow all rules in `agents/rules/`.
- Follow commit conventions in `agents/rules/commit-conventions.md`.

## Release/Distribution Channels

- CLI distributions: `repos/cli` and `repos/ops`
- Server image/crate: `repos/server`
- Worker image/crate: `repos/worker`
- Gateway image/crate: `repos/gateway`
- Shared crates: `repos/tools`

## Available Skills

- `memory-add` — create and commit a memory inbox entry
- `memory-compact` — compact inbox entries into a summary
- `sync-note` — create a sync note from the template
- `bump-pointer` — update a submodule pointer after upstream merge
