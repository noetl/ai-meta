# Docs Coverage Audit — NoETL Agent Diagnostics and Triage Models

Task: `20260506-032648-docs-only-triage-model-and-coverage`

Source scope: `repos/docs/docs/` at `noetl/docs@e9d1523`.

## Topic Matrix

| Topic | Status | Current Docs | Last Updated | Notes |
|---|---|---|---|---|
| T1. Gap 1 — agent envelope contract + sub-execution wait-for-terminal | PARTIAL | `docs/architecture/agent_orchestration.md` | 2026-05-05 | The envelope shape and `framework: noetl` sub-playbook dispatch are documented, but the Gap 1 lesson is not named: agent sub-executions must reach a terminal state before downstream envelope extraction depends on them. |
| T2. Gap 4.1 — auto-troubleshoot hook + persisted-diagnosis fetch + retry race | PARTIAL | `docs/architecture/agent_orchestration.md`, `docs/architecture/self_troubleshoot_agent.md` | 2026-05-05 / 2026-05-04 | Auto-troubleshoot and parity checks are documented, but the wait-then-fetch contract for persisted diagnosis, required diagnosis keys, and the retry race are not collected as an operator/developer reference. |
| T3. `kind: agent` tool-error carve-out | PARTIAL | `docs/architecture/agent_orchestration.md` | 2026-05-05 | The envelope says `status: "error"` is valid agent output, but the worker carve-out is not explicit: agent envelope errors are not generic worker `tool_error` coercions. |
| T4. Event-projection contract and `_extract_control_context` chokepoint | PARTIAL | `docs/architecture/agent_orchestration.md` | 2026-05-05 | The nested diagnosis path and parity smoke are covered. The named chokepoint, the carve-out pattern, and the "add fixture + carve-out together" rule are missing. |
| T5. Live-vs-persisted parity smoke | COVERED | `docs/architecture/agent_orchestration.md` | 2026-05-05 | Static and cluster invocations are present, including the `NESTED_DICT_LOSS` failure mode. |
| T6. `bump_image` lifecycle agent + GHCR availability probe | PARTIAL | `docs/operations/gcp/gke-cloudsql-end-to-end.md`, release/deployment docs | 2026-04-30 | GHCR pull troubleshooting is documented for GKE, but the lifecycle agent's GHCR probe and idempotent bump path are not described as their own operational contract. |
| T7. Five prepared smokes as a regression suite | PARTIAL | `docs/architecture/agent_orchestration.md`, `docs/regression-testing.md` | 2026-05-05 / 2026-04-24 | Individual smoke references exist for optional AI and parity. The five-smoke battery and what each protects are not presented together. |
| T8. Ollama bridge + MCP integration | COVERED | `docs/operations/ollama_bridge.md`, `docs/reference/tools/mcp.md`, `docs/architecture/playbook_as_mcp_server.md`, `docs/gui/terminal-console.md` | 2026-05-04 / 2026-04-30 | Covers JSON-RPC, MCP-as-playbook, catalog registration, GUI routing, and the no-direct-browser-to-MCP rule. |
| T9. Auto-troubleshoot escalation path | PARTIAL | `docs/architecture/self_troubleshoot_agent.md`, `docs/architecture/agent_orchestration.md` | 2026-05-04 / 2026-05-05 | `confidence_threshold` and `escalate_to` are documented, including Claude escalation. The relationship between default model, workload override, and confidence-driven escalation needs a focused model-selection page. |
| T10. Agent-to-agent bridge pattern | COVERED | `docs/ai-meta/how-agents-work.md`, `docs/ai-meta/agent-orchestration.md`, `docs/ai-meta/shared-memory-multi-engineer.md` | existing | The file-based task/result workflow, shared memory, and agent profiles are covered for Claude/Codex collaboration. |
| T11. Default models — `gemma3:4b`, `gemma4:e4b`, `qwen3:32b` | MISSING | Existing docs still mention `gemma2:2b` / `qwen2.5:7b` in AI triage paths. | 2026-05-04 / 2026-05-05 | This is the required PR 1 gap. Docs need to state that `gemma3:4b` remains the default, `gemma4:e4b` is opt-in with measured cgroup math, and `qwen3:32b` is the escalation tier. |
| T12. Spike e2e workflow as worked example | PARTIAL | `docs/architecture/agent_orchestration.md` | 2026-05-05 | The commands are present, but the parent → `trigger_failure` → `extract_envelope` → assertion flow and what each step proves are not explained cohesively. |
| T13. Operational rules from `AGENTS.md` | PARTIAL | `docs/development/docker_usage.md`, `docs/development/kind_kubernetes.md`, `docs/ai-meta/*` | 2026-04-30 / 2026-04-24 | Podman is documented generally. The current repo rules around Podman-only kind, `/Volumes:/Volumes`, and unsetting `XDG_DATA_HOME` are not in docs as a local-cluster operations note. |

## Gap Summary

### HIGH

- **T11 triage model selection.** Operators currently see stale `gemma2:2b` / `qwen2.5:7b` examples in the auto-troubleshoot and Ollama bridge docs. They need one canonical page explaining the default (`gemma3:4b`), the production opt-in (`gemma4:e4b`), the escalation tier (`qwen3:32b`), and the 2026-05-06 cgroup-memory finding.
- **Agent failure diagnostics contract (T1, T2, T3, T4, T7, T12).** The pieces exist across several pages, but there is no single reference for the shipped Gap 1 / Gap 4.1 contract: agent envelope errors are data, not worker failures; sub-executions and diagnoses must be waited for and fetched from persisted events; projections must preserve nested `error.diagnosis`; and the spike + five smokes protect that path.

### MEDIUM

- **T6 `bump_image` GHCR probe.** Deployment docs mention GHCR pulls, but not the lifecycle-agent probe and clean idempotent path.
- **T13 local Podman operational rules.** General Podman docs exist, but the `ai-meta` operational rules should be promoted into user-facing local-kind guidance.

### LOW

- **T10 agent-to-agent bridge.** Covered in the AI-meta docs; no immediate gap-fill needed.
- **T8 MCP/Ollama bridge.** Covered, though existing examples should be updated away from older model names as part of PR 1.

## Recommended 2-PR Plan

1. **PR 1: `docs: document triage model tradeoffs`.** Add `docs/architecture/triage_model_selection.md`, update stale model references in agent/bridge docs, and add the page to the Architecture sidebar. This closes T11 and improves T9.
2. **PR 2: `docs: document agent failure diagnostics contract`.** Add one cohesive architecture page covering Gap 1, Gap 4.1, the `kind: agent` carve-out, projection preservation, the spike e2e workflow, and the five-smoke regression battery. This closes the HIGH thematic group across T1, T2, T3, T4, T7, and T12.

Deferred follow-ups after the two-PR cap:

- Add a short operations note for `bump_image` GHCR probe behavior and idempotent image bumps.
- Add local-kind Podman-only rules to the operations/development docs, including `/Volumes:/Volumes` and `XDG_DATA_HOME` hygiene.
