# Codified ephemeral-blueprints execution model (architecture + agent rule)
- Timestamp: 2026-05-24T17:54:49Z
- Author: Kadyapam
- Tags: architecture,execution-model,rules,agents,docs,knowhow

## Summary
User articulated the foundational shape: gateway=gatekeeper only, worker=atomic compute blocks, playbook=ephemeral blueprint (control flow + policy), shared cache=state vehicle (Arrow IPC, execution_id-scoped), event log=source of truth. Any data touch happens only inside a playbook step under that playbook's policy. No persistent per-tenant AI-agent or MCP-server processes; an AI agent is a directed sequence of blocks, an MCP server is a playbook in the catalog. Callback/hook pattern: blocks initiating long-running external work capture execution_id + callback subject, return immediately, release the worker slot; the callback handler applies the incoming payload to the latest state of the execution_id and emits the resume event, letting the next block claim off NATS. This is the platform's knowhow for cost-effective, performance-optimized agentic AI. Codified in three places: (1) repos/docs/docs/architecture/ephemeral_blueprints.md at sidebar position 1 (noetl/docs PR #169, branch kadyapam/ephemeral-blueprints-execution-model); (2) agents/rules/execution-model.md for AI agents; (3) CLAUDE.md + AGENTS.md updated to put the new rule second in the session-start read-list, right after AGENTS.md. Companion to the travel-ui round-03 work (gateway #11 + travel #50 PRs) — that work was the first concrete enforcement of this boundary (removing direct Firebase SDK from the SPA).

## Actions
-

## Repos
-

## Related
-
