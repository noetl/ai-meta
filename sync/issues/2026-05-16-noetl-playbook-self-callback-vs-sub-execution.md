# Sync Note: 2026-05-16 — NoETL playbook self-callback vs sub-execution

## Summary
- The travel itinerary planner currently fires off a sub-execution for every MCP tool call (firestore append, duffel search/order, amadeus hotels, google places). Each turn spawns 8–11 child executions, each tracked in `noetl.execution` with its own command + event chain.
- User flagged this as overhead and proposed: "playbook does not need to call other playbook all the time, it may use callback the same playbook and go to the step where it is needed to go."
- Two implementation paths exist; both are real work, and the right call deserves a dedicated round rather than being bolted onto the sidebar PR.

## Scope (Repos)
- repos/noetl: only path #1 below — would add a new DSL primitive (`tool: kind: jump` or `tool: kind: callback`) that dispatches to a named step in the current playbook without creating a child `executionId`. Touches the engine's executor, event chain, and arc routing.
- repos/ops: only path #2 — replace `tool: kind: agent, framework: noetl, entrypoint: automation/agents/mcp/<x>` with inline `kind: python` + `urllib`/`psycopg` invocations of the underlying provider, bypassing the agent indirection entirely. Loses the MCP-as-playbook architecture for these callers.
- repos/travel: consumer either way — its `itinerary-planner.yaml` does most of the agent dispatching today.

## PRs / Links
- (none yet — this note is the design gate before opening any PRs)

## Resulting SHAs / Tags
- TBD after path is chosen.

## Compatibility / Notes
- Backward compatible: depends on path
  - Path #1 (new DSL primitive): backward compatible. Existing playbooks keep working with `kind: agent`. New primitive opt-in.
  - Path #2 (inline MCP in itinerary planner): backward compatible at the playbook level; breaks the "MCP is just a playbook" thesis for these specific calls; doesn't touch other consumers of `mcp/firestore`, `mcp/duffel`, `mcp/amadeus`.
- Migration required:
  - Path #1: existing playbooks could optionally migrate hot paths to the new primitive to reduce sub-execution count, but no forced migration.
  - Path #2: travel playbook rewrite of every step currently using `kind: agent` against `automation/agents/mcp/*`. Loses inspection/replay benefits of separate executions.
- Config/DSL impact:
  - Path #1: new DSL keyword. Spec docs in `noetl/docs/docs/features/noetl_dsl_refactoring_spec.md` need an addendum. Schema in `repos/noetl/noetl/core/dsl/playbook.schema.json` updates.
  - Path #2: no DSL change.
- Known risks:
  - Path #1: arc evaluation already tripped us up twice this week (TaskResultProxy cross-step references) — a new dispatch primitive is another surface for the same class of bug. Needs careful test coverage for context propagation and `set:` interaction.
  - Path #2: dropping the MCP indirection makes credential management leak into the consumer playbook (keychain has to be set up by the itinerary planner instead of the duffel MCP). Multiple consumers would need to repeat that wiring.
  - Both: even after either change, sub-executions are still created by `mcp/firestore.append_event` on every turn — that's actually called 5+ times per turn. The per-call overhead, not the per-tool overhead, may be the real cost.

## Trade-off summary

| Concern | Path #1 (DSL primitive) | Path #2 (inline in playbook) |
|---|---|---|
| Engine change | yes (large) | no |
| Loses MCP abstraction | no | yes |
| Other consumers benefit | yes | no |
| Time to ship | weeks (DSL + tests + spec) | days (travel-only rewrite) |
| Reduces firestore overhead | yes if used | yes for the rewritten paths |
| Inspection/replay value | preserved | lost (no sub-exec to query) |

## Recommendation
Open this as two separate decisions:

1. **If the goal is "reduce per-turn execution count for the travel demo"**: pick Path #2 (inline MCP calls in `itinerary-planner.yaml`). Smallest blast radius, ships fast, accepts loss of MCP abstraction for those specific calls.
2. **If the goal is "give every NoETL playbook author a way to avoid sub-execution overhead"**: pick Path #1 (new DSL primitive). Slower but lifts a ceiling for everyone, including future PFT/travel/AI-OS playbooks.

Both could be done in sequence: #2 unblocks the demo this week, #1 lands later and lets us migrate back to MCP-style indirection without the overhead.

## Follow-ups
- [ ] Decide path #1 vs #2 (or both, with #2 first).
- [ ] If #1: open spec draft in `repos/noetl/docs/features/` and an issue in `noetl/noetl` repo.
- [ ] If #2: design which MCP tools become inline in `itinerary-planner.yaml` (firestore append_event seems first; duffel search/create_order would require token plumbing).
- [ ] Either way: instrument `noetl.execution` counts per parent playbook so we can quantify the actual reduction before/after.

## Memory Entries
- (to be written after path is chosen and shipped)

## Verification
- Tests run: none yet — this is a design note.
- Environments verified: n/a.
- Observability notes: a useful baseline metric is `count(*) from noetl.execution where parent_execution_id = X` per travel itinerary turn — currently ~11 in test mode.
