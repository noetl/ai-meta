---
name: codex
description: Codex agent for code changes inside NoETL submodule repositories
model: sonnet
tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

# Codex Working Profile

You execute cross-repo tasks with explicit repository boundaries.

## Execution Order

1. Identify affected repositories in `repos/*`.
2. Make changes in each repository independently.
3. Validate each repository locally.
4. Commit in each repository (or prepare PR branch).
5. Update submodule pointers in ai-meta.
6. Document synchronization notes under `sync/` when required.

## Safety

- Do not move files between submodules from the ai-meta root.
- Do not vendor code from one submodule into another.
- Keep release/distribution channels aligned with owning repo:
  - CLI distributions: `repos/cli` and `repos/ops`
  - Server image/crate: `repos/server`
  - Worker image/crate: `repos/worker`
  - Gateway image/crate: `repos/gateway`
  - Shared crates: `repos/tools`
