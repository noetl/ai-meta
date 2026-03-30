# noetl/gateway issue draft: Codex Runtime Contract (M1)

- Date: 2026-03-27
- Repo: `noetl/gateway`
- Issue: https://github.com/noetl/gateway/issues/5
- Labels: `program:codex-runtime`, `area:gateway`, `type:design`, `priority:p0`

## Proposed title

`design(gateway): validate and align session/runtime contracts for noetl ai operations (M1)`

## Problem summary

AI-driven operational flows from `noetl` require stable gateway session/auth and runtime proxy contracts that match CLI tool invocation requirements.

## Requested direction

- Validate current `/noetl/*` proxy and auth/session flows for AI-commanded operations.
- Document required endpoint contracts for `exec`, `status`, `catalog`, `cancel`, and diagnostics.
- Identify and implement minimal gateway changes needed for M1 compatibility.

## Acceptance criteria

- Contract matrix produced for CLI tool operations vs gateway endpoints.
- Any required gateway changes merged with compatibility notes.
- Integration validation documented for:
  - direct API mode (`/api/*`)
  - gateway proxy mode (`/noetl/*`)
- No regression for existing non-AI gateway usage.

## Dependencies

- Paired `noetl/cli` M1 issue for pass-through and AI bootstrap.
- Program plan: `playbooks/noetl-codex-cli-gateway-program-plan.md`.

## Related

- `sync/noetl-codex-change-requests.md` (`CR-20260327-1`)
