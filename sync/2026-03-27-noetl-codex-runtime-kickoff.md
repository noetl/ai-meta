# Sync Note: 2026-03-27 — NoETL Codex Runtime Kickoff

## Summary
- Started cross-repo program to encapsulate Codex capability in `noetl` CLI.
- Added development plan with lockstep `repos/cli` + `repos/gateway` milestones.
- Added centralized change-request register for scope and contract management.

## Scope (Repos)
- repos/cli: planned `noetl codex` passthrough + `noetl ai` bootstrap + tool bridge.
- repos/gateway: planned runtime endpoint/session alignment for AI-driven operations.
- repos/docs: planned operator/DSL retrieval and usage docs updates.
- ai-meta: orchestration plan, change-request tracking, and memory update.

## PRs / Links
- ai-meta: pending
- noetl/cli issue: https://github.com/noetl/cli/issues/4
- noetl/cli PR: https://github.com/noetl/cli/pull/5
- noetl/gateway issue: https://github.com/noetl/gateway/issues/5
- noetl/gateway PR: https://github.com/noetl/gateway/pull/6
- noetl/docs issue: https://github.com/noetl/docs/issues/9
- noetl/docs PR: https://github.com/noetl/docs/pull/10
- noetl project: https://github.com/orgs/noetl/projects/2

## Resulting SHAs / Tags
- repos/cli: unchanged (planning phase)
- repos/gateway: unchanged (planning phase)
- repos/docs: unchanged (planning phase)

## Compatibility / Notes
- Backward compatible: yes (planned requirement)
- Migration required: no (for initial M1)
- Config/DSL impact: none in kickoff phase
- Known risks:
  - contract drift between cli and gateway if issues are not linked per milestone

## Follow-ups
- [x] Create GitHub issue in `noetl/cli` for M1 (`noetl codex` passthrough + doctor).
- [x] Create paired GitHub issue in `noetl/gateway` for M1 endpoint/session contract validation.
- [x] Create GitHub Project `NoETL AI Runtime Program` and add both issues.
- [ ] Add labels in each repo: `program:codex-runtime`, `area:*`, `type:*`, `priority:*`.

## Memory Entries
- memory/inbox/2026/03/20260327-211227-noetl-codex-runtime-program-started.md

## Verification
- Tests run: N/A (docs/planning change only)
- Environments verified: N/A
- Observability notes: N/A
