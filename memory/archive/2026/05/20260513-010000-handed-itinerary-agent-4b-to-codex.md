# Handed LLM-driven itinerary agent to Codex (trip-planner Round 4b)

- date: 2026-05-13T01:00:00Z
- tags: trip-planner, adiona, muno, itinerary-agent, llm, event-sourcing, hybrid-input, codex-handoff, round-4b

## Round goal

Build the trip-planner's LLM-driven itinerary agent inside the muno
repo at `muno/playbooks/itinerary-planner.yaml`. Hybrid input (scripted
widget submissions + free-form chat), per-turn LLM extraction step, tool
dispatch through mcp/duffel + mcp/google-places + mcp/amadeus + mcp/firestore.
Emits widget envelopes that match the 23 schemas frozen in Round 4a/6a.

Runs PARALLEL with Round 6b (real Material widget components). Disjoint
paths in muno — 4b touches `muno/playbooks/` only, 6b touches
`muno/src/` only.

## Decisions locked

- **Lives in muno**, not repos/ops. Trip-planner-specific per the home-
  base rule.
- **Hotels source: Amadeus** (Duffel Stays sales-gated per Round 2).
- **flight_provider: duffel** (default from existing travel runtime).
- **Test mode only**. Production endpoints FORBIDDEN — LLM cannot
  override workload's `amadeus_env: test` / `duffel_env: test`.
- **Per-turn LLM extraction step** with strict JSON output. Slot updates
  + tool requests + render intent.
- **All emitted widgets validate** against `muno/playbooks/widget-contract/`.
  Invalid → fall back to `bot_text` describing the agent's intent.
  Never crash.
- **All events through mcp/firestore.append_event** (mandatory header
  redaction).
- **Replay mode**: temp=0 + model pinning + tool responses replayed
  from events/api_calls. Slot updates and widget_type sequence must be
  byte-identical; agent_chat text drift tolerated.
- **muno PR via standard flow** (no direct-to-main this round). First
  feature PR on muno.

## Pre-handoff (DONE, verified)

No new GCP secrets, no new IAM, no new MCP servers. All upstream rounds
GREEN: mcp/firestore v6, mcp/duffel v5 (with orders), mcp/google-places,
mcp/amadeus, muno bootstrap at 4143d4c.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-010000-itinerary-agent-4b.task.json`
- `scripts/itinerary_agent_4b_msg.txt`

## Trigger prompt for Codex

```
Implement the LLM-driven itinerary agent at muno/playbooks/itinerary-planner.yaml.
Hybrid input (scripted widgets + free-form chat). Per-turn LLM
extraction → tool dispatch → widget chat step. Event-sourced via
mcp/firestore. Hotels via Amadeus (Duffel Stays sales-gated). Test
mode only. Trip-planner Round 4b. Runs parallel with Round 6b.

Bridge task: bridge/inbox/delegated/20260513-010000-itinerary-agent-4b.task.json
Prompt details: scripts/itinerary_agent_4b_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-010000-itinerary-agent-4b.result.json

Pre-handoff (DONE): all upstream rounds GREEN. No new secrets / IAM.

Run all 8 phases per the bridge task. Architectural rules:
  - Lives in muno/playbooks/. NOT repos/ops.
  - No frontend changes (Round 6b's territory).
  - Hotels source: Amadeus only.
  - Test-mode endpoints only. Production FORBIDDEN.
  - All widget emissions validate; invalid → bot_text fallback.
  - All event log writes through mcp/firestore.append_event.
  - LLM provider via workload.ai_provider; extraction REQUIRES JSON mode.
  - Smoke threads under chat_threads/_smoke-{nonce}; cleanup at end
    of phase 6.
  - muno PR via standard flow (NOT direct-to-main).
  - ai-meta pointer bump local-only.
  - If Round 6b's PR lands first: rebase before merging.
```

## What's after this round

- **Round 5** — Google Calendar integration (pushes Firestore events
  to a shared project calendar).
- **Round 7** — End-to-end tutorial (cap-stone; depends on 4b + 6b
  both shipping).

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260512-235900-firestore-mcp-event-sourcing-green.md`
- `memory/inbox/2026/05/20260513-002608-muno-bootstrap-container-build-green.md`
- `memory/inbox/2026/05/20260512-230000-duffel-stays-unavailable-round-2.md`
- `bridge/inbox/delegated/20260513-010500-muno-material-widgets-6b.task.json` (parallel round)
- `muno/playbooks/widget-contract/*.schema.json`
