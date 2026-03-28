# Change Requests: NoETL Codex Runtime Program

Use this register to track scope changes, contract changes, and follow-up requests across `repos/cli`, `repos/gateway`, and supporting repos.

## Request Template

- ID: `CR-YYYYMMDD-<n>`
- Date:
- Requested by:
- Summary:
- Driver: `feature | bug | risk | compliance | ops`
- Impacted repos: `cli | gateway | docs | ai-meta | other`
- Linked issues:
  - cli:
  - gateway:
  - docs:
  - ai-meta:
- Project card:
- Priority: `p0 | p1 | p2`
- Risk level: `low | medium | high`
- Target milestone: `M1 | M2 | M3 | later`
- Proposed change:
- Contract impact:
- Compatibility impact:
- Test/validation plan:
- Decision: `accepted | deferred | rejected`
- Decision date:
- Owners:
- Notes:

## Active Requests

### CR-20260327-1

- Date: 2026-03-27
- Requested by: product/engineering direction
- Summary: Embed full Codex CLI power inside `noetl` while preserving NoETL-specific operator capabilities.
- Driver: feature
- Impacted repos: cli, gateway, docs, ai-meta
- Linked issues:
  - cli: https://github.com/noetl/cli/issues/4
  - gateway: https://github.com/noetl/gateway/issues/5
  - docs: https://github.com/noetl/docs/issues/9
  - ai-meta: TODO
- Project card: https://github.com/orgs/noetl/projects/2 (issues added)
- Priority: p0
- Risk level: medium
- Target milestone: M1 -> M3
- Proposed change:
  - Add `noetl codex` passthrough with behavior parity.
  - Add `noetl ai` with NoETL context/tool bootstrap.
  - Align gateway and cli contract changes for runtime operations.
- Contract impact:
  - New/updated gateway endpoints may be required for AI-driven runtime operations.
- Compatibility impact:
  - Existing CLI commands must remain backward compatible.
- Test/validation plan:
  - parity tests for passthrough
  - integration tests across gateway-proxy and direct API modes
  - safety confirmation tests for mutating commands
- Decision: accepted
- Decision date: 2026-03-27
- Owners: TODO
- Notes:
  - Track all repo issues under label `program:codex-runtime`.
  - Issue creation succeeded, but custom labels were not found in target repos at creation time.
  - Implementation PRs opened: noetl/cli#5, noetl/docs#10, and noetl/gateway#6.
