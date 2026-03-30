# Program Plan: NoETL CLI + Gateway Codex Runtime

## Objective

Build `noetl` into an AI-native operator tool by embedding full Codex CLI capability and NoETL-aware runtime tools, with `repos/cli` and `repos/gateway` delivered in lockstep.

## Scope

- In scope:
  - `repos/cli`: Codex passthrough, AI mode bootstrap, tool bridge, safety controls.
  - `repos/gateway`: runtime endpoints/session flows needed by AI operations.
  - `repos/docs`: DSL/operator docs for retrieval grounding.
  - `ai-meta`: orchestration notes, memory, pointer sync, cross-repo tracking.
- Out of scope (initial program):
  - Replacing upstream Codex behavior.
  - Proprietary/non-public secrets or environment-specific credentials.

## Architecture Guardrails

- Keep full upstream Codex behavior available via `noetl codex ...` pass-through.
- Add NoETL-native AI mode via `noetl ai` with preloaded context and tools.
- Use one internal tool contract for model providers; avoid provider-specific logic in command handlers.
- Keep `repos/cli` and `repos/gateway` API contracts versioned and tested together.
- Require explicit confirmation for destructive operations.

## Milestones

### M1: Codex Integration Baseline

- `repos/cli`
  - Add `noetl codex` transparent passthrough (args/stdin/stdout/tty).
  - Add `noetl codex doctor` (install/auth/version checks).
  - Add `noetl ai` command scaffold.
- `repos/gateway`
  - Confirm required auth/session endpoints are stable for AI command flows.
- Exit criteria:
  - `noetl codex` parity verified against direct `codex`.
  - Basic AI session starts from `noetl ai`.

### M2: NoETL Tool Bridge + Safety

- `repos/cli`
  - Register typed tools for core operations (`exec`, `status`, `catalog`, `context`, `auth`).
  - Add tool execution audit logs and secret redaction.
  - Add confirmation gates for mutating commands.
- `repos/gateway`
  - Ensure gateway proxy flows support tool-driven operations end-to-end.
- Exit criteria:
  - AI can execute core operational tasks through typed tools only.
  - Safety checks enforced in non-interactive and interactive modes.

### M3: Knowledge + Ops Expansion

- `repos/cli`
  - Local knowledge indexing/retrieval over DSL/docs/memory/submodules.
  - Add operator bundles for k8s, postgres, NATS, logs, GKE workflows.
- `repos/gateway`
  - Add/adjust endpoints needed for diagnostics and execution introspection.
- `repos/docs`
  - Publish AI operator usage and safety docs.
- Exit criteria:
  - AI answers with grounded source references.
  - Incident triage workflows are reproducible through CLI.

## Cross-Repo Delivery Process

1. Open linked issues in each impacted repo with shared milestone label.
2. Implement in repo branches (`repos/cli`, `repos/gateway`, docs as needed).
3. Validate contracts and integration tests.
4. Merge repo PRs.
5. Bump submodule SHAs in `ai-meta` in one atomic sync commit.
6. Add sync note and memory entry.

## GitHub Issue Model

- Issue labels:
  - `area:cli`, `area:gateway`, `area:docs`, `area:ai-meta`
  - `type:feature`, `type:bug`, `type:design`, `type:tracking`
  - `program:codex-runtime`
  - `priority:p0|p1|p2`
- Linking:
  - Every `repos/gateway` issue linked to paired `repos/cli` issue if contract-related.
  - Use parent tracking issue per repo for milestone rollup.

## GitHub Projects Model

- Project: `NoETL AI Runtime Program`
- Columns:
  - `Backlog`, `Ready`, `In Progress`, `In Review`, `Blocked`, `Done`
- Required fields:
  - `Repo`, `Milestone`, `Priority`, `Risk`, `Owner`, `Target Release`
- Automation:
  - Auto-add issues with `program:codex-runtime`.
  - Move to `In Review` on PR open; `Done` on merge.

## Change Control

- All change requests recorded in:
  - `sync/noetl-codex-change-requests.md`
- Non-trivial scope changes require:
  - issue update in affected repos
  - project card update
  - memory entry in `ai-meta`

## Reporting Cadence

- Daily:
  - update project board statuses
  - post short sync in issue threads
- Per merge batch:
  - add `sync/` note
  - update `ai-meta` submodule pointers
  - add memory entry

## Definition of Done (Program Increment)

- CLI + Gateway contract tests pass.
- Operator safety checks pass.
- Docs updated for new commands and runbooks.
- `ai-meta` points to merged SHAs and contains sync/memory updates.
