# Firestore calendar view Round 5 GREEN

Muno Round 5 shipped the Firestore-only calendar view. The widget catalogue now has 24 templates, adding `calendar_view` plus generated TypeScript, sample envelopes, renderer dispatch, and a real Material `CalendarView` component with static `display_events` and live Firestore `events_path` modes.

The itinerary agent now extracts calendar-note turns, emits a `calendar_view` widget, and writes calendar event documents through `mcp/firestore.set_doc`. GKE live smoke `625590045860168070` rendered `calendar_view` variant `full` and wrote `chat_threads/_smoke-calendar-1778643344/trip/current/events/note_c02f7361e9`; the smoke documents were deleted afterward.

Important fix-forward lessons from the live smoke:

- NoETL Python helper functions and imported symbols still need explicit `globals().update(...)` publication.
- Comprehensions/generator expressions can also resolve through globals, so avoid them or publish captured locals.
- Dicts crossing Jinja step boundaries may arrive as JSON strings or Python-literal dict strings; `_as_dict` now handles both with `json.loads` and `ast.literal_eval`.
- For stable render handoff, `extract_turn.json_str` is more reliable than nested projected fields.
- The guest Firestore path must be a valid document hierarchy: `chat_threads/{thread}/trip/current/events/{eventId}`, not `chat_threads/{thread}/trip/events/{eventId}`.

Firestore rules were authored but not deployed. They document demo-permissive unauthenticated reads and blocked browser writes; real auth/rules tightening remains a later round.
