# Travel sidebar history + new search button shipped
- Timestamp: 2026-05-16T04:17:10Z
- Author: Kadyapam
- Tags: travel,sidebar,history,ux,closed

## Summary
Sidebar replaced static Searches/Orders toggle with collapsible sections listing per-session history. Orders rows come from order_confirmation widgets keyed by booking_reference; Searches rows come from flight_list/hotel_list/place_list/itinerary_summary/calendar_view widgets with widget-type icons and short subtitles. Click a row -> activates view + scrolls chat to that bubble with brief highlight via background-color transition. New search button in ChatThread header aborts in-flight request, clears localStorage thread id, mints fresh one, resets messages+slot+view. Thread id persisted to localStorage on first mount so page reload keeps the conversation (was minting a fresh travel-ui-* id every page load). Files: src/components/shell/Sidebar.tsx (full rewrite with HistorySection sub-component), src/components/shell/ChatThread.tsx (summary derivation, scroll effect, startNewSearch handler, localStorage), src/App.tsx (wires summary state + scrollToMessageId + setActiveView callback). PR noetl/travel#48. Validation: type-check, smoke:widgets, vitest (19/19), build all green; new bundle index-CFKRWCHb.js. Deferred follow-ups: (a) cross-session history listing past trips across reloads/devices -- needs a list/query primitive on mcp/firestore that doesn't exist today; (b) playbook self-callback architecture instead of sub-execution per MCP call -- design captured in sync/issues/2026-05-16-noetl-playbook-self-callback-vs-sub-execution.md with path #1 (new DSL primitive) vs path #2 (inline MCP in travel playbook) trade-offs.

## Actions
-

## Repos
-

## Related
-
