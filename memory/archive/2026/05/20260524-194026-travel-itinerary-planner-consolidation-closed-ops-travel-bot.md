# Travel itinerary-planner consolidation closed; ops + travel + both wikis bumped
- Timestamp: 2026-05-24T19:40:26Z
- Author: Kadyapam
- Tags: travel,ops,wiki,consolidation,closed,latency

## Summary
PRs #118 (noetl/ops) and #51 (noetl/travel) merged. Ops 887a3b5 lands the firestore MCP batch helpers (batch_set_docs, batch_get_docs, batch_append_events) with internal fan-out preserving append_event transaction/seq/redaction semantics. Travel aa234ff lands the consolidated itinerary-planner playbook: 24 declared steps -> 14, ~18 executed per provider-backed turn -> 11, ~8 firestore MCP parent steps per turn -> 4. Wikis pushed alongside (Rule 1b coupling): noetl-travel-wiki c55d8d7 reflects the new step shape and measured GKE timings, noetl-ops-wiki be04744 adds the new agents-mcp-firestore page documenting the MCP method surface. Live cluster already runs the consolidated playbook (codex registered version 40 during the round's pre-authorized live-validation phase). The <2s latency target was NOT met: live runs measured 8.846s / 12.494s / 15.213s. Structural reduction is real but per-step platform overhead remains the dominant cost. Codex's analysis pins next bottleneck on nested-playbook completion accounting + worker event-write overhead — addressed by the queued noetl-platform-step-overhead-reduction handoff. Two other follow-ups also identified during the round and queued separately: noetl-executions-listing-stale-status (zombie RUNNING listings) and noetl-keychain-leak-redaction (live security finding — opened as handoff b17e404 awaiting dispatch). Thread 2026-05-24-travel-itinerary-planner-consolidation archived.

## Actions
-

## Repos
-

## Related
-
