---
name: codex
description: Claude Code subagent for Codex-style code work inside NoETL submodule repositories
model: sonnet
tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
skills:
  - memory-add
  - memory-compact
  - sync-note
  - bump-pointer
  - handoff-open
  - handoff-result
  - issue-open
  - issue-close
---

@agents/profiles/codex.md
