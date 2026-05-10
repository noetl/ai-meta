# Travel hotels/activities round closes GREEN — four-branch travel agent live

- date: 2026-05-10T20:00:00Z
- tags: travel-agent, hotels, activities, amadeus-mcp, agent-hop, green, capacity-note

## What landed

- Ops PR (primary): noetl/ops#61 — hotels/activities MCP wiring
- Ops PR (in-flight): noetl/ops#62 — helper-scope fix
- Ops PR (in-flight): noetl/ops#63 — activity coordinate fallback
- Docs PR: noetl/docs#53 — tutorial 07 mentions all four branches
- GKE travel runtime re-registered, smoke complete
- ai-meta 10 commits ahead of origin/main (workload-defaults docs round +
  hotels/activities round, both pushed eventually together)

## GREEN smoke evidence

- Help, flights, locations, hotels, activities — all five produce
  app:column widgets
- Hotels classifier extracted `cityCode=PAR` (LLM IATA mapping working)
- Activities classifier extracted Times Square coordinates `40.758, -73.9855`
  (LLM landmark→geocode mapping working, with the ops#63 coordinate fallback
  catching cases where extraction returns null)
- Amadeus test API still 500s on some calls — friendly-error widget path
  is the validated output for those, exactly as designed

## In-flight regressions Codex caught and patched

1. **Helper-scope fix (ops#62)**: NoETL's separate globals/locals model again.
   The hotels/activities classifier extension touched the merger; helper
   functions weren't visible across nested closures. Same root cause as the
   Phase 3 vertex-ai round's `globals().update(...)` fix. Worth flagging as
   recurring NoETL-Python idiom — should be in the authoring guide.
2. **Activity coordinate fallback (ops#63)**: when the LLM returns null for
   latitude/longitude, the runtime needs to either default to NYC center
   (per the design brief) or short-circuit to a friendly error. Codex
   landed the default fallback so activities never hits Amadeus with null
   coords.

Both fixes are small and surgical. The pattern of catching and patching
within the round (rather than punting to a follow-up) is the right shape.

## Capacity note

GKE workers were briefly scaled up during smokes — restored to 2 desired /
2 ready before close-out. Port-forward on localhost:18082 closed. Resource
state clean.

## Travel agent state after this round

| intent     | tool surface         | render widget          |
| ---------- | -------------------- | ---------------------- |
| help       | render_help          | app:column with help text |
| flights    | search_flights       | app:column / carousel  |
| locations  | search_locations     | app:column / recordtable |
| hotels     | search_hotels        | app:column / recordtable |
| activities | search_activities    | app:column / recordtable |

All four real branches go through `automation/agents/mcp/amadeus` via
`tool: agent framework: noetl`. The Phase 1 stub comment is gone. The
travel agent is now a complete demonstration of NoETL's "MCP is just a
playbook" thesis across all the agent's capabilities.

## Lurking design debt confirmed

The classifier system prompt is in TWO places (Python const for http branch
+ payload `system` arg for vertex branch). When this round extended the
schema (cityCode, latitude, longitude), both had to be edited together.
This is real coupling. A future architectural-purity round should extract
the prompt into a single workload field (or a small helper python step
that emits the prompt as `output.system_prompt`) referenced by both
branches. Not urgent — but flag it before it bites.

## Recurring NoETL-Python idiom worth a future authoring-guide rule

NoETL executes Python snippets with separate globals/locals maps. Helper
functions defined at the top of a step's `code` block are visible to the
top-level statements but NOT to OTHER helpers via closure unless explicitly
republished via `globals().update({...})`. This bit Phase 3 (vertex merger)
AND this round (hotels/activities classifier extension). Worth a 13th rule
in the playbook authoring guide:

> Republish helpers through globals before calling them from other helpers.
> NoETL evaluates Python snippets with separate globals/locals dicts; the
> default behavior of nested function calls breaks unless you explicitly
> `globals().update({...})` the helper names.

Not in scope for this round — but capture it for the next docs round.

## Deferred follow-ups remaining (in order)

3. app:form widget for refining Amadeus filters before re-running (NEXT)
4. Audit table re-add as side effect inside each render_* python step (psycopg)
5. Anthropic re-smoke once GCP secret is provisioned (gated on user)
6. Ollama provider — needs in-cluster bridge URL routing design
7. Investigate Amadeus test API 500s on flights/locations
8. (NEW) NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. (NEW) Single-source-of-truth refactor for the classifier system prompt
