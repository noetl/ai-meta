# Codex Working Profile

## Objectives

- Execute cross-repo tasks with explicit repository boundaries.
- Keep changes localized to the correct submodule.
- Return to `ai-meta` repo only for pointer/instruction updates.

## Execution order

1. Identify affected repositories in `repos/*`.
2. Make changes in each repository independently.
3. Validate each repository locally.
4. Commit in each repository (or prepare PR branch).
5. Update submodule pointers in `ai-meta` repo.
6. Document synchronization notes under `sync/` when required.

## Safety

- Do not move files between submodules from `ai-meta` root.
- Do not vendor code from one submodule into another.
- Keep release/distribution channels aligned with owning repo:
  - CLI distributions: `repos/cli` and `repos/ops`
  - Server image/crate: `repos/server`
  - Worker image/crate: `repos/worker`
  - Gateway image/crate: `repos/gateway`
  - Shared crates: `repos/tools`
