# Muno itinerary agent 4b GREEN

Muno PR #1 landed the first feature PR on `noetl/muno`: an event-sourced
itinerary-planner playbook at `playbooks/itinerary-planner.yaml`, extraction
and chat system prompts, canonical widget envelope examples, a registration
helper, a smoke helper, and a filled architecture document.

The implementation keeps the home-base boundary: the agent lives in Muno, not
`repos/ops`, and all event writes go through `mcp/firestore.append_event`.
Hotels remain Amadeus-only and all provider calls are test-mode.

Result file:
`bridge/outbox/20260513-010000-itinerary-agent-4b.result.json`.
