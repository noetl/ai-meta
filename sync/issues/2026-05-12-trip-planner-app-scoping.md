# Trip-planner chat app (Adiona / muno) — scoping

Date: 2026-05-12
Status: scoping locked — bridge rounds queued from this doc

## Vision

End-user-facing trip planner that walks a traveller from "I want to go
somewhere" to a saved itinerary with reminders. Chat-first UX with rich
widget cards in the thread, sidebar for orders/searches history,
contextual right-pane for search options and promotions.

Tutorial outcomes the app demonstrates:

1. Describe a trip in chat → AI parses dates/origin/destination/preferences.
2. Search **places** at the destination (Google Places: photos, ratings,
   reviews, hours, types).
3. View **maps** of key locations (Maps Static).
4. Search **flights** (Duffel `search_offers`) for matching dates.
5. **Place a test-env Duffel order** for chosen flights (free, synthetic
   payment, real-looking order shape).
6. Search **hotels** (Duffel Stays if beta is open to us; Amadeus hotels
   otherwise).
7. **Save the itinerary** to Firestore with notes, references to the
   underlying Duffel/Amadeus orders, and traveller details.
8. **Generate calendar events** for flight departures, arrivals, check-in,
   check-out — stored as Firestore documents on the same trip; later phase
   pushes to Google Calendar.
9. **Visualize** everything as chat-bubble widgets + side-panel
   summaries in the muno app.

## Decisions locked (from Kadyapam 2026-05-12)

1. **Orders**: **Duffel test-env only.** No live orders, no real payment.
   Synthetic orders against synthetic offers are free and risk-free —
   ideal for tutorial flow. `duffel-api-live` remains a placeholder
   gated on Thread 3.
2. **Duffel Stays (hotels)**: investigate beta access. If available on
   our Duffel test account, use it as the hotels source for the tutorial.
   If not, fall back to Amadeus hotels (with documented 500-flake caveat).
3. **Storage**: **Firestore.** A `trips` collection stores trip
   documents; a `calendar_events` collection stores schedule entries.
   Better-idea pushback: instead of one flat "calendar table", model as
   `users/{uid}/trips/{tripId}` with `events` and `orders` subcollections
   (per-user access rules are clean, queries stay scoped, and we can
   later mirror events to Google Calendar without restructuring). See
   the "Firestore data model" section below.
4. **Figma source**: `/Volumes/X10/projects/adiona/figma/Adiona_material/`
   (Chat-Main.png, Chat-Main-{1,2,3}.png, Group 320.png, Mail.svg) plus
   the prototype URL the user shared. UI patterns extracted in the
   "UI patterns" section below.
5. **UI repo**: `git@github.com:noetl/muno.git` (empty, just created).
   Bootstrap as React 18 + TypeScript + Vite + MUI (Material UI v6+ for
   Material Design 3). Matches `repos/gui`'s tooling for cross-app code
   sharing (API client, types, build pipeline) but uses MUI instead of
   Ant Design because the Figma is Material.

## Current state — what's already in place

| Capability | Where | Notes |
|---|---|---|
| Flights search | `repos/ops/automation/agents/mcp/duffel.yaml` | Search-only as of round 20260512-130000. `search_offers`, `get_offer`, `search_places`, `get_airlines`. |
| Flights provider selector | `repos/ops/automation/agents/travel/runtime.yaml` | `flight_provider: duffel \| amadeus`, default `duffel`. |
| Places + Maps Static + Photos | `repos/ops/automation/agents/mcp/google-places.yaml` | Pattern C hybrid auth (SA OAuth backend + restricted widget key). |
| Hotels (current) | `repos/ops/automation/agents/mcp/amadeus.yaml` | `search_hotels`. Test 500s tracked in `sync/issues/2026-05-11-amadeus-test-api-500s.md`. |
| Activities | `mcp/amadeus.search_activities` | Same 500-flake caveat. |
| Widget rendering | `travel/runtime` render steps | Per-execution, no chat thread state. |
| GKE deployment | `gke_noetl-demo-19700101_us-central1_noetl-cluster` | Workload Identity + secret manager wired. |

## Gaps — what needs building

Seven discrete work items, sequenced as bridge rounds:

### Round 1 — Duffel order creation (test env only)

Add to `mcp/duffel.yaml`:
- `create_order` — POST /air/orders with the chosen offer + test-payment
  block. Returns order id + booking reference.
- `get_order` — GET /air/orders/{id}.
- `list_orders` — GET /air/orders. For history surfaces.

Locked: test env only; live token path stays placeholder. Per-execution
cap: 1 order per call.

### Round 2 — Duffel Stays availability check + hotels source decision

**CLOSED 2026-05-12: Stays NOT available** — `POST /stays/search` and
`GET /stays/bookings` both returned 403 with explicit sales-contact
messaging ("This feature is not enabled for your account. Please
contact sales to get access: https://duffel.com/contact-us"). Probe
details in
`memory/inbox/2026/05/20260512-230000-duffel-stays-unavailable-round-2.md`.

Decision locked: **Round 4 uses Amadeus hotels** (`mcp/amadeus.search_hotels`)
as the hotels source. Lives with the known test 5xx flake; the
friendly-failure render path is already proven by execution
`625309687340073612` from round 20260512-130000. Re-evaluate Duffel
Stays only if Kadyapam initiates a commercial conversation with Duffel.

No PRs, no travel runtime changes, no new secrets. One read-only probe
from a worker pod with cleanup.

### Round 3 — Firestore MCP + event sourcing + replay tooling

New `mcp/firestore.yaml`. Tools:
- `set_doc` — write/upsert a document at a path.
- `get_doc` — read a document.
- `query_collection` — query with simple where/order/limit clauses.
- `delete_doc` — delete (used for tearing down test fixtures).
- `append_event` — append-only insert into a `{threadId}/events`
  subcollection with monotonic `seq`. Auto-redacts known sensitive
  header keys (`Authorization`, `X-Goog-User-Project`, etc.) on
  write.
- `replay_events` — read an event range and return the structured log
  for re-feeding through the agent.

Plus a small bridge-side helper script in `scripts/firestore_replay.sh`
that walks a thread's event log and reads Firestore docs with the
operator's local `gcloud` credentials. The future agent-diff mode
(`replay --against-agent`) belongs to Round 4 after the itinerary agent
exists.

Auth: Workload Identity on `noetl-worker-mcp` SA. Grant the SA
`roles/datastore.user` on the project (Firestore lives under Datastore
APIs).

Pre-handoff (Kadyapam, one-time): enable Firestore in Native mode on
`noetl-demo-19700101` if not already; grant `roles/datastore.user`.

Status 2026-05-12: GREEN via ops#86 and docs#66. GKE registered
`automation/agents/mcp/firestore` as catalog version 6
(`625474366091821164`). Smokes passed for tools/list, set/get,
query_collection, append_event seq `[1,2,3,4,5]`, mandatory header
redaction, type-filter replay, `scripts/firestore_replay.sh`, and
cleanup. `_smoke` was verified empty after the run.

### Round 4 — LLM-driven itinerary agent (hybrid input)

New `muno/playbooks/itinerary-planner.yaml` (lives in muno, not ops —
trip-planner-specific per the "Home base" decision). LLM-driven
multi-turn agent with hybrid input (scripted widgets + free-form chat),
as detailed in the "Agent: hybrid linear + free-form input" section.
First deliverable in this round is `muno/playbooks/widget-contract/*.schema.json`
and `muno/docs/architecture/widget-contract.md` — the closed-catalogue
schema set that Round 6 codes its renderers against.

Per-turn loop:
1. Read the latest event (user message OR widget submission OR widget
   CTA click).
2. LLM step: extract slot updates and/or tool requests from the event,
   given current `current_slot_state` and recent thread context.
3. Apply slot updates → append `agent_slot_update` event.
4. If a tool call is needed: dispatch via existing MCP playbooks
   (`mcp:google-places`, `mcp:duffel`, `mcp:amadeus`); append
   `agent_tool_call` and `agent_tool_response` events; record full
   request/response in `events/api_calls`.
5. LLM step: decide what to render next — bot chat bubble, widget,
   widget composition, or clarification question.
6. Append `agent_widget_emit` or `agent_chat` event(s); the UI picks
   them up via Firestore live listener.

Uses `mcp:google-places`, `mcp:duffel`, `mcp:amadeus`, and the new
`mcp:firestore` for event append. Doesn't replace the existing
`automation/agents/travel/runtime` — that runtime stays for one-shot
intent queries; the itinerary planner is a parallel agent with
multi-turn state and event-sourced history.

The agent emits widgets per the "AI-generated / dynamic widgets"
contract. Widget schemas are versioned (`schema_version: 1`) so
breaking renderer changes can be detected on replay.

### Round 5 — Google Calendar integration (deferred until Round 4 ships)

New `mcp/google-calendar.yaml`. Same SA OAuth pattern Google Places
uses. Tools:
- `create_event` — push a Firestore-stored calendar event to Google
  Calendar.
- `update_event`, `delete_event` — sync subsequent edits.

Calendar target: project-owned shared calendar
(`noetl-trip-events@group.calendar.google.com` or similar). Avoids the
per-user OAuth consent flow until we have real user accounts. When the
muno app grows real auth (Round 6+), we can flip to user-owned
calendars.

### Round 6 — muno repo bootstrap (frontend + playbooks + docs + memory + .claude)

Bootstrap `git@github.com:noetl/muno.git` as the full project home base
per the "muno is the home base" section above — not just a frontend
scaffold. Initial commit lays down:

- React 18 + TypeScript + Vite + MUI frontend (`src/`).
- 3-column shell matching Figma: left sidebar, centre chat thread,
  right contextual panel (property block / filters / promo modes).
- Widget renderer infrastructure that reads
  `playbooks/widget-contract/*.schema.json` and emits TS types into
  `src/contracts/widgets.ts` at build time. Schema-validation at the
  render boundary; unknown widgets fall back to `bot_text`.
- `playbooks/` directory with placeholder for the itinerary planner
  (Round 4 fills it).
- `docs/` skeleton (architecture / deployment / auth / tutorial /
  runbooks subfolders, each with a stub README).
- `memory/` skeleton with `current.md`, `inbox/claude/`, `inbox/codex/`
  layout. Mirrors `ai-meta/scripts/memory_add.sh` and `memory_compact.sh`
  in `muno/scripts/`, scoped to write into `muno/memory/`.
- `.claude/settings.json` with permission allowlists for the local
  muno dev loop (npm/vite/typescript checks). Rules and skills
  symlinked from `../../ai-meta/agents/` where applicable so muno
  inherits shared rules without duplicating them.
- `AGENTS.md` / `CLAUDE.md` at the repo root pointing at the relevant
  docs and the memory dir.
- Docker + nginx packaging analogous to `repos/gui`.

After the initial commit, add as `repos/muno` submodule under
ai-meta.

This round produces the working chat shell + the project's home base
for everything that follows. Auth is "Guest" only initially (matches
the Figma). The renderer can display widgets the moment Round 4's
agent emits them.

Status 2026-05-13: AMBER with bootstrap complete. `noetl/muno` was
initialized on `main` at `ec43ade` with 23 widget payload schemas plus
the envelope schema, generated `src/contracts/widgets.ts`, React 18 +
TS + Vite + MUI v6 shell, AJV widget validation, JSON stub renderers,
docs, scripts, memory skeleton, `.claude`, Dockerfile, and nginx config.
`ai-meta` added `repos/muno` as a local submodule commit `a201c6a`.
Validation passed for `npm install`, schema compile, `npm run
type-check`, `npm run build`, and `npm run smoke:widgets`. The only
unfinished check is container build verification: local `docker` is not
installed and the configured Podman API socket refused connections even
after restarting the `noetl-dev` machine. No code or schema validation
failed.

### Round 7 — End-to-end tutorial (the cap-stone)

New `repos/docs/docs/tutorials/08-trip-planner-end-to-end.md`. Walks
the reader through:
- Starting a trip in muno.
- Searching places, viewing maps.
- Picking a flight (Duffel test order placed).
- Picking a hotel.
- Reviewing the saved itinerary in Firestore.
- Seeing calendar events generated.

Includes screenshots from the muno app, executions IDs as proofs, and
a "what's not covered" section about real-money booking gating.

Status 2026-05-13: GREEN via docs#67. The capstone tutorial is merged at
`repos/docs/docs/tutorials/08-trip-planner-end-to-end.md` with eight UI
screenshots under `static/img/tutorials/trip-planner-end-to-end/`.
`npm run build` passed in `repos/docs`. The tutorial is explicit that
the v1 flow is test-environment only, cites real execution IDs from the
Duffel, Firestore, Google Places, and calendar rounds, includes a
Firestore replay walkthrough, and names the remaining v1 polish gaps
instead of overselling the demo. With this round, the trip-planner
project is feature-complete for the tutorial arc.

## UI patterns extracted from the Figma

Observations from the 5 PNG exports + 1 SVG asset:

**Layout — 3-column shell**:
- **Left** (~220px, vivid blue): app logo + name "Adiona Travel",
  guest profile chip, search box, primary nav ("Orders", "Searches"),
  promotional card ("Sing up to see your orders search history").
- **Centre** (~700px, flexes): chat thread with avatar+bubble pattern;
  hero illustration as initial empty state; input bar pinned bottom
  with send-as-paper-plane icon.
- **Right** (~340px, white): contextual panel. Default state shows
  Telegram CTA + "Most Popular Hotels" card. During an active search,
  swaps to "Search options" accumulator showing the user's collected
  inputs.

**Chat bubble shape**:
- Bot avatar: blue circle with white "A".
- User avatar: real photo (top-right of own message).
- Bot bubbles: light grey background, rounded right-bottom, anchored
  left. Timestamp under each.
- User bubbles: white card with shadow, rounded left-bottom, anchored
  right.
- Bot has a "typing" indicator at the bottom of the chat area.

**Inline widgets within the chat**:
- Travel illustration (hero card) inserted as a bot message.
- Autocomplete dropdown over the input area when the user is typing a
  destination (place suggestions).

**Smart widgets (interactive forms-in-bubbles)** — the bot doesn't only
send text; it can embed structured input widgets inline in the thread.
Observed from the additional Figma screens:

- **Calendar date-range picker**: two-month side-by-side view (current +
  next month), arrow nav to flip months, click-and-drag range selection
  (selected days highlighted blue, in-range days in light blue), Submit
  button. Used for "What are your preferred travel dates?" After submit,
  the user's chat bubble echoes the dates in readable form
  (e.g., "Check-in 2020-01-08 · 12 nights · Check-out 2020-01-09"
  — the mocked 2020 dates in the Figma are just placeholders), and the
  right-pane property block gains Check in / Check out / nights fields.
- **Traveller-party widget**: rows for Rooms / Adults / Children with
  +/- steppers, plus a Child Age dropdown per child (with options
  `< 1 year`, `1 year`, `2 year`, etc.), Submit button. Used for
  "How many adults and children?" Echoes as a structured bubble on
  submit.
- **Hotel result card (in-chat)**: full-width card inside a bot bubble.
  Large photo on the left with a numbered carousel (`1/18` style),
  prev/next arrows. Right column: location label, hotel name, star
  rating (filled yellow stars), score badge (e.g., `7.8`), thumbs-up /
  thumbs-down counts (`1760 / 14`), a highlighted "Rooms matching
  request: 54" pill, and a short About hotel description. Bottom action
  row carries two CTAs: **Watch In Detail** + **Show Numbers**.
  The compact list variant (`Group 320.png`) is the same shape with
  amenity icons + price + Show all rooms; used in result lists.
- **Action-chooser widget**: bot offers next-step choices as a row of
  illustrated cards each with a CTA button — e.g., "Would you like to
  see more results?" → cards `More Results` / `See On Map`. Lives
  inside a bot bubble. Treat as a navigation-only smart widget (no
  structured payload, just one of N choices).
- **(Implied) Flight offer picker**: select-from-a-list widget over
  Duffel `search_offers` results. Same shape language as the hotel card
  (photo / title / sub-info / score / dual CTA).
- **(Implied) Itinerary review widget**: at the end of the flow, a
  summary card with destination, dates, party, picked flight, picked
  hotel, and a "Confirm" CTA.

Common widget contract:
- `widget_type: date_range | party | flight_picker | hotel_card | hotel_picker | review | action_chooser`
- `widget_payload`: type-specific schema (min/max dates, allowed
  cabin classes, hotel record + filter context, action choices, etc.).
- `widget_state`: pending | submitted (rendered as read-only echo) |
  ambient (cards that don't require submission — hotel display cards
  the user reads but doesn't "submit", with embedded CTAs).
- `submitted_value`: structured choice (echoed in the user bubble and
  pushed to the right-pane property block, when applicable).
- `cta_clicked`: identifier of the chosen action button (e.g.,
  `watch_in_detail`, `show_numbers`, `more_results`, `see_on_map`).
  Routes back to the agent which can react with a new bot turn.

**Right-pane "property block"** (`Search options`):
- Progressively accumulates the structured slots the user has filled.
- Each row shows a label and the current value, with a pencil icon for
  retroactive edit (re-opens the corresponding smart widget in the
  thread).
- Mirrors the itinerary agent's working slot state in real time.
- Visible only while a trip-planning conversation is active; default
  state is the Telegram CTA + "Most Popular Hotels" preview.

Observed property-block fields across the Figma screens (the slot
catalogue the itinerary agent collects):

| Field | Source widget | Notes |
|---|---|---|
| Region | destination text input + place autocomplete | `Country, City [, Subdivision]` |
| Check in / Check out / nights | calendar date-range picker | nights derived from range |
| Rooms and Guests | traveller-party stepper | rooms + adults + children + per-child ages |
| Star rating | (later widget — likely a chip group) | e.g., "5 star hotels" |
| Budget | (later widget — likely a range slider) | currency-aware, e.g., "$110-$1800" |
| Bed Type | (later widget — chip group) | "Twin bed", etc. (Figma has "Twin bad" typo — ignore) |
| Other Amenities | (later widget — multi-select chips) | Breakfast, Fitness center, Meeting rooms, etc. |

The itinerary agent collects the first three slots before any
search runs. The remaining slots are progressively refined inside the
result-browsing turns (the bot offers "Show Numbers" / filter widgets to
tighten the search).

**Map view** (sibling to the chat thread, route `/trips/:tripId/map`):
- The centre column swaps from chat thread to a full-bleed **Google
  Maps JS** embed (not Maps Static — markers and panning need
  interactivity).
- Hotel results render as teardrop **price markers** (`$1006` style
  badge in the marker shape).
- Selected marker shows a **popover card**: photo carousel (`1/18`),
  location label, hotel name, star rating, score (`7.8/10`), thumbs
  counts, "Available rooms: 16", "$110.40 per night", and a primary
  CTA ("View Rooms" / `Смотреть Номера`).
- Left sidebar (orders/searches nav) stays.
- Right sidebar swaps from `Search options` property block to a
  **`Filters`** panel:
  - Hotel Category checkboxes (5⭐ … 2⭐).
  - Budget range slider with min/max thumbs.
  - Guest Rating tiers (`9.5+`, `9+`, `8.5+`, …).
  - `Clear All` link at the top.
- Toggling from chat view to map view preserves the slot state — the
  filters in the map view are the same property-block slots in a
  different surface.

**Right-pane modes** (the right sidebar has three states):
1. Default / Guest landing → Telegram CTA + Most Popular Hotels preview.
2. Active trip planning → `Search options` (property block / slot
   accumulator with edit pencils).
3. Map view → `Filters` (interactive filter controls; reflects same
   slot state).

**i18n note** — the Figma map screen shows `Смотреть Номера` (Russian)
on the hotel-popover CTA while the rest of the design is English. The
left sidebar has an `EN` language toggle (visible across the screens).
Treat all visible strings as translation candidates from the start —
externalize copy into a locale file in muno (`src/locales/en.json`,
`src/locales/ru.json`) and wire react-i18next or similar. Not blocking
v1, but cheap to bake in early.

**Hotel card** (Group 320.png):
- Photo carousel with arrows, "max 7 photos" badge.
- Heart icon (favorite), 8.5km distance, star rating, address, distance
  from center.
- Amenity icon strip (8-10 small icons).
- Price block with currency + "for a night for N guests".
- Rating: numeric score badge (e.g., 7.2) + review count.
- Conditional banners (annotated "1" and "2" in the export):
  - "No meals / No free cancellation" (current filter state)
  - "Rooms with meals and free cancellation are available!" (upsell
    nudge to broaden the search)
- "2 rooms For 3 adults" + "Show all rooms" CTA.

**Design tokens** to lock in MUI theme:
- Primary blue (sidebar / paper-plane icon).
- White surface, light-grey thread background.
- Typography: sans-serif (system stack ok; Inter or Roboto target).
- Rounded corners (~8-12px).
- Soft drop shadows on cards.

## Firestore data model proposal

Structure (Native mode):

```
users/{uid}                        # user metadata (later)
  trips/{tripId}                   # trip document
    summary: { destination, dates, traveller_count, currency, notes }
    chat_thread_id: <ref>
    created_at, updated_at
    events/{eventId}               # calendar entries
      type: flight_depart | flight_arrive | check_in | check_out | activity
      start_at, end_at, timezone
      title, location, notes
      google_calendar_event_id: <nullable>
    orders/{orderId}               # Duffel order references
      provider: duffel
      duffel_order_id, booking_reference
      offer_snapshot (denormalized — Duffel offers expire)
      status, total_amount, currency
      created_at
    notes/{noteId}                 # free-text user notes
      body, created_at

chat_threads/{threadId}            # chat history (separated for query patterns)
  messages/{msgId}
    role: user | assistant | system
    content, widgets, timestamp
    trip_ref: <nullable>
```

Why subcollections under trip:
- Per-user / per-trip security rules stay simple.
- Calendar queries by trip ("show me all events for this trip") are
  natural.
- Mirroring to Google Calendar (Round 5) updates `events/{eventId}` in
  place — no schema migration when we add `google_calendar_event_id`.

Why chat threads separate:
- Chat history grows independently of trips; messages may reference
  trips but aren't owned by them.
- Allows guest chats (no `users/{uid}` parent) — matches the Figma's
  "Guest" sidebar state.

Initial security rules will be permissive (single-tenant demo); we
tighten when real auth lands.

## muno is the home base for this project (LOCKED)

Kadyapam's call: everything trip-planner-specific lives **inside the
muno repo**, not split across ai-meta/repos. The repo is the
project's monorepo for code + playbooks + docs + AI memory. Bridge
orchestration stays in ai-meta (where the codex infra lives); muno
holds the project-specific work product.

### What goes where

| Lives in | Contents |
|---|---|
| **`noetl/muno`** | React frontend (`src/`), trip-planner playbooks (the LLM-driven itinerary agent), widget template schemas, project documentation (architecture, deployment, auth, tutorial), AI session memory (Claude + Codex), `.claude/` config, project-scoped scripts. |
| **`noetl/ai-meta`** | Submodule pointer to `repos/muno`. Cross-repo coordination notes that bridge muno + ops + docs. Bridge round artefacts (task JSONs, codex prompts). Project-wide ai-meta memory (other tracks, not trip-planner-internals). |
| **`noetl/ops`** | Shared MCP infrastructure: `mcp/duffel.yaml` (gains `create_order` etc.), `mcp/firestore.yaml`, `mcp/google-places.yaml`, `mcp/google-calendar.yaml`. Things any agent could use, not trip-planner-only. |
| **`noetl/docs`** | General NoETL docs + the end-user tutorial that links into muno. |
| **`noetl/noetl`** | Core engine — no trip-planner code lands here. |

Rule of thumb: if removing trip-planner from the project would mean
deleting the file, it lives in muno. If the file is reusable
infrastructure (an MCP tool other agents could call), it lives in
`repos/ops`.

### Stack

- React 18 + TypeScript 5
- Vite 7 build tool
- MUI v6 (Material UI 3) for components
- React Router v6 for `/`, `/trips/:tripId`, `/trips/:tripId/map`, `/orders`, `/searches`
- Axios for NoETL server API calls
- Firebase JS SDK for live Firestore listening (chat thread updates,
  trip projection reads). Server-side writes go through the NoETL
  `mcp/firestore` hop so we don't ship a Firebase service-account
  credential in the browser.
- react-i18next for the `EN` / `RU` language toggle from the Figma.

### Initial muno repo shape

```
muno/
  README.md
  AGENTS.md                              # shared AI entry point
  CLAUDE.md                              # Claude Code entry point (mirrors ai-meta's pattern)
  .gitignore

  # ---------- Frontend ----------
  package.json                           # React + MUI + Vite + i18next deps
  tsconfig.json
  vite.config.ts
  index.html
  Dockerfile                             # mirrors repos/gui packaging
  nginx.conf
  src/
    main.tsx
    App.tsx                              # 3-column shell
    theme.ts                             # MUI theme (eventually fed by Figma variables)
    locales/
      en.json
      ru.json
    components/
      shell/   (Sidebar.tsx, RightPane.tsx, ChatThread.tsx, InputBar.tsx)
      widgets/ (BotText.tsx, HotelCard.tsx, FlightList.tsx, DateRangePicker.tsx,
                PartyPicker.tsx, ActionChooser.tsx, MapView.tsx, PropertyBlock.tsx,
                FilterPanel.tsx, ItinerarySummary.tsx, OrderConfirmation.tsx, ...)
      primitives/ (Avatar.tsx, Stepper.tsx, TypingIndicator.tsx, ...)
    api/
      noetlClient.ts
      firestoreClient.ts
    contracts/                           # generated from playbooks/widget-contract/*.schema.json
      widgets.ts                         # TS types for all widget payloads
  public/
    favicon.svg

  # ---------- NoETL playbooks ----------
  playbooks/
    itinerary-planner.yaml               # LLM-driven hybrid-input agent (Round 4)
    widget-contract/                     # canonical schemas — source of truth for both agent and UI
      bot_text.schema.json
      hotel_card.schema.json
      flight_list.schema.json
      flight_card.schema.json
      date_range_picker.schema.json
      party_picker.schema.json
      action_chooser.schema.json
      map_view.schema.json
      filter_panel.schema.json
      property_block.schema.json
      itinerary_summary.schema.json
      order_confirmation.schema.json
      ... (rest of the 18-template catalogue)
    deployment/
      register-with-noetl.sh             # registers playbooks against the NoETL server

  # ---------- Documentation ----------
  docs/
    architecture/
      event-sourcing.md                  # Firestore event log + replay model
      widget-contract.md                 # widget template contract, schema versioning
      agent-design.md                    # hybrid input flow, LLM extraction loop
      data-model.md                      # users/trips/events/api_calls schema
    deployment/
      kind-setup.md
      gke-setup.md
      figma-pat-setup.md                 # how to provision figma-access-token
    auth/
      firebase-setup.md                  # for later, when Firebase Auth lands
      guest-mode.md                      # v1 default
    tutorial/
      end-to-end.md                      # the Round 7 cap-stone tutorial
    runbooks/
      replay-a-session.md                # how to use scripts/firestore_replay.sh

  # ---------- AI session memory ----------
  memory/
    current.md                           # active working state for this project
    inbox/
      claude/                            # Claude Code session notes (this kind of session)
        2026/
          05/
            20260512-<slug>.md
      codex/                             # Codex round outcomes
        2026/
          05/
            20260512-<slug>.md
    compact/
      2026/
        05/

  # ---------- Claude Code config ----------
  .claude/
    settings.json                        # permissions, hooks scoped to muno
    rules/                               # symlinks to shared ai-meta/agents/rules where applicable
    skills/                              # muno-specific or shared skills
    agents/                              # subagent defs

  # ---------- Project-scoped scripts ----------
  scripts/
    memory_add.sh                        # mirrors ai-meta but writes to muno/memory/
    memory_compact.sh
    firestore_replay.sh                  # replay tool from Round 3
    figma_fetch.sh                       # mirror of ai-meta's helper, scoped to muno needs
```

Bridge round artefacts (task JSONs, Codex prompts, handoff memory)
still live in `ai-meta/bridge/` and `ai-meta/scripts/` — the bridge
infra is shared across all tracks. The handoff memory entries in
ai-meta cross-link to the muno-side outcome memory.

### Submodule wiring

After the first muno commit lands:

```bash
cd /Volumes/X10/projects/noetl/ai-meta
git submodule add git@github.com:noetl/muno.git repos/muno
git commit -m "chore(sync): add repos/muno submodule for trip-planner project"
```

Submodule pointer bumps follow the existing `chore(sync): bump muno
to <sha>` pattern after each muno PR merges.

### Memory entries — where each one lives

- `memory/inbox/claude/...` inside muno: notes from Claude Code
  sessions working on muno itself (UI work, playbook design,
  architecture decisions). This session's outcomes would land here
  once muno exists.
- `memory/inbox/codex/...` inside muno: post-round outcome notes
  from Codex bridge rounds that touched muno or trip-planner
  playbooks.
- `ai-meta/memory/inbox/...`: the handoff entry (`handed-X-to-codex`)
  stays in ai-meta because the bridge infra lives there. After Codex
  lands, the outcome note goes in muno; the ai-meta memory just
  cross-links.

### What this round (the scoping doc commit) puts where

- `ai-meta/sync/issues/2026-05-12-trip-planner-app-scoping.md` — this
  document, since it spans multiple repos.
- `ai-meta/scripts/figma_fetch.sh` — the helper, since the Figma file
  is referenced from many places.
- (Future) `muno/docs/architecture/widget-contract.md` — once muno
  exists, an extracted, expanded version of the widget contract
  section of this doc moves there.

Bootstrap commit message for muno's first commit:
`chore: bootstrap muno (trip-planner chat app + playbooks + docs + memory)`

## Agent: hybrid linear + free-form input (LOCKED)

The itinerary agent supports **two coexisting input channels** into the
same slot state. Both run every turn; whichever fires first updates
the slot state and triggers the next step.

1. **Scripted widget input** — calendar submit, stepper submit, action-
   card click, etc. Structured JSON event with known schema.
2. **Free-form chat input** — the user types a message in the input
   bar at any point. Examples:
   - "actually make it 4-star hotels under $200"
   - "show me only flights leaving after noon"
   - "I want to compare these two hotels side by side"
   - "skip hotels, just find flights"

An LLM-driven extraction step consumes the free-form text PLUS the
current slot state and emits one of:
- A slot update (`{ region: "Miami, FL" }` or
  `{ star_rating_min: 4, budget_max: 200 }`).
- A tool call request (`mcp/duffel:search_offers` with current slots).
- A widget render request (see "AI-generated widgets" below).
- An ambiguous-input clarification (bot asks back).

Either input channel produces the same downstream effects:
- Update slot state in Firestore.
- Echo the change to the user as a chat bubble.
- Refresh the right-pane property block / filter pane.
- Optionally trigger a follow-up search or widget.

This means the agent is genuinely **LLM-driven**, not a state-machine
wizard. The "linear wizard" feel is achieved by the LLM choosing to ask
one question at a time when slots are empty, not by hardcoded
question-order logic. The same agent gracefully handles
"book-me-a-trip-to-Miami-next-month-for-2-adults" in one message vs the
step-by-step Figma flow.

## Event-sourced storage + replay (LOCKED)

Every user action AND agent decision is persisted as a discrete event
in Firestore. The trip document is a **projection** over the event
stream — it can always be reconstructed from events.

```
chat_threads/{threadId}
  thread_meta: { user_uid, created_at, updated_at, trip_ref? }
  events/{eventId}                         # append-only event log
    seq: <monotonic int>
    timestamp: <server ts>
    type: user_message | user_widget_submit | user_widget_cta_click |
          agent_slot_update | agent_tool_call | agent_tool_response |
          agent_widget_emit | agent_chat | agent_clarify | system
    payload: <type-specific schema>
    parent_seq: <nullable — for branching scenarios>

trips/{tripId}                             # projection of events that touched this trip
  summary: { destination, dates, traveller_count, currency, notes }
  current_slot_state: { region, check_in, check_out, party,
                         star_rating, budget, bed_type, amenities, ... }
  picked_flight: <Duffel offer snapshot>
  picked_hotel: <Duffel/Amadeus hotel snapshot>
  orders: [<order refs>]
  events_seq_range: { from, to }           # which events composed this projection

events/api_calls/{callId}                  # full request/response audit
  thread_id, event_seq                     # link back to which event triggered it
  tool: mcp/duffel:search_offers | ...
  request: { url, method, headers_redacted, body }
  response: { status, headers_redacted, body }
  duration_ms
  error: <nullable>
```

Headers are redacted at write time (drop `Authorization`,
`X-Goog-User-Project`, etc.). Bodies are stored verbatim for replay.

**Replay semantics**:
- Take any `chat_threads/{threadId}/events` range and re-feed it
  through the agent.
- The agent is deterministic given (events + tool responses replayed
  from `events/api_calls`).
- Diff produced events against the original to detect drift (agent
  prompt changed, model changed, etc.).
- Useful for: debugging "what made the agent decide X", regression
  testing after agent changes, audit trail for orders.

This is **event-sourcing lite**, not full CQRS. We don't optimize the
projection-rebuild path; we keep `trips/{tripId}` as a snapshot that's
updated on each event for read performance, but the events log is the
source of truth.

Tooling for replay lands alongside the `mcp/firestore` round (or in a
dedicated round; see "Suggested sequencing" updates).

## Pre-templated widgets, AI-adjustable (LOCKED)

Widgets are **pre-templated** — the renderer knows the full catalogue
ahead of time, and every emitted widget matches one named template
with a known schema. The AI does NOT invent new widget types and does
NOT free-form compose UI. The AI's discretion is bounded to what each
template's schema allows: which template to pick, which variant of
that template to render, and how to populate the fields.

Closed catalogue = predictable rendering, schema-validatable on the
wire, replay-stable across model upgrades.

Template schema shape:

```
{
  "widget_type": "<one of the catalogue names>",   // closed set
  "variant": "<one of the template's variant ids>", // e.g. "compact" | "full"
  "payload": <fields per the template's schema>,
  "ai_adjustments": {                              // optional, bounded
    "emphasis": "<one of the template's emphasis slots>",
    "annotations": [<bounded note objects the template supports>],
    "conditional_fields": { <flags the template knows about> }
  },
  "schema_version": <int>
}
```

Where AI can adjust **within a template**:

- **Variant pick**: `hotel_card` template might define `compact` and
  `full` variants. AI picks the one that fits the data (e.g., `compact`
  in a list of 10, `full` when the user asked to "show me more about
  this hotel").
- **Emphasis**: a `flight_list` template defines an `emphasis_offer_id`
  field. AI sets it when the user asks "what's the cheapest non-stop?"
  → the renderer highlights that card.
- **Conditional banners**: `hotel_card` defines a
  `upsell_banner: { text, action_label }` optional field. AI fills it
  when relaxing a filter would expose better options ("Rooms with
  meals and free cancellation are available!" from `Group 320.png`).
- **Annotations**: AI can attach short notes to specific data points
  if the template's schema declares an `annotations[]` field.
- **Field selection / hiding**: schema marks some fields as required,
  others optional. AI populates what's relevant.

Where AI **cannot** go:

- Inventing a new `widget_type` — anything not in the catalogue gets
  rejected at validation. The fallback is "emit a known
  `bot_text` widget describing the situation in natural language" —
  not "emit a free-form rich_text payload that bypasses templates."
- Arranging widgets outside what templates declare — e.g., side-by-
  side hotel comparison only renders if there's a `hotel_compare`
  template with a `slots: [hotel_card_a, hotel_card_b]` schema. If
  there isn't, the AI emits a `bot_text` saying "Comparing X vs Y..."
  plus two separate `hotel_card` widgets in sequence.

Renderer behaviour:
- Validate `widget_type`, `variant`, `payload` against the registered
  template schemas. Unknown widget_type or invalid payload → log
  error, render a `bot_text` saying "Unable to render this response
  (template mismatch)" rather than crashing.
- Versioned schemas — a template at `schema_version: 2` can render
  payloads from `1` if the schemas are backwards-compatible; otherwise
  the renderer falls back to `bot_text`.

Initial template catalogue (the closed set for v1, expandable in
later rounds):

- `bot_text` — plain-text bot bubble (markdown allowed).
- `user_text` — echo bubble for user-typed message.
- `typing_indicator` — "AdionaBot is typing…".
- `date_range_picker` (interactive).
- `party_picker` (interactive — rooms/adults/children + child ages).
- `place_autocomplete_input` (interactive — destination text input
  with Duffel `search_places` / Google Places suggestions).
- `flight_list` — N flight cards with optional emphasis.
- `flight_card` (variants: compact, full).
- `hotel_list` — N hotel cards with optional upsell banner.
- `hotel_card` (variants: compact, full, in-popover).
- `hotel_compare` — two hotel_cards side-by-side (only if Kadyapam
  signs off on having this in v1; defer otherwise).
- `place_list` / `place_card` — Google Places enrichment results.
- `action_chooser` — illustrated CTA cards row (`More Results` /
  `See On Map`).
- `map_view` — embedded Maps JS with markers + filter panel state.
- `filter_panel` — right-pane interactive filters (star rating,
  budget, guest rating, etc.).
- `property_block` — right-pane slot accumulator (the
  `Search options` pane).
- `itinerary_summary` — end-of-flow review widget with destination,
  dates, party, picked flight, picked hotel, Confirm CTA.
- `order_confirmation` — Duffel test order receipt with booking ref.
- `notification` — toast-style notification (`mes_notification`
  Figma component).
- `error_card` — graceful failure surface.

Templates beyond this list require an explicit catalogue extension
(small PR adding the schema + renderer component); the AI cannot
synthesize them ad-hoc.

## Open architecture questions

(Q1 "linear wizard vs LLM-driven" is now LOCKED to LLM-driven hybrid —
see the "Agent: hybrid linear + free-form input" section above.)

2. **muno auth model**: "Guest" only for now (matches Figma left sidebar
   state), or wire Firebase Auth / Google sign-in from day one?
   Recommend guest-only for v1; the Firebase Auth wiring is a separate
   round (Round 8+).

3. **Maps Static vs. embedded Google Maps JS** — answered: **both**.
   The chat thread uses Maps Static PNGs (cheap, fast, key-protected
   via widget secret). The dedicated `/trips/:tripId/map` view uses
   embedded Maps JS (interactive markers, popovers, panning). Adds a
   Maps JS-enabled key restriction to the widget API key (or a second
   key restricted to Maps JS). Captured in the muno scaffold.

4. **Telegram bot mention in sidebar**: the Figma shows "Join our
   Telegram Bot @Adiona" as a CTA. Is that aspirational placeholder,
   or do you actually want a Telegram bot wired? If aspirational,
   leave the chip as static UI for now.

5. **Search-options accumulator on the right pane**: as the user
   answers the bot's questions, the right pane accumulates the answers
   (Figma Chat-Main-3 shows "Search options: United States of America,
   Miami"). This implies the itinerary agent maintains structured slot
   state alongside the chat. Confirm this is the right read — the right
   pane mirrors the agent's working memory of trip parameters.

## Suggested sequencing

Critical insight: rounds 4 (agent) and 6 (muno UI) can run truly in
parallel ONLY if the widget JSON contract between them is locked
upfront. This scoping doc captures the contract sketch; the first
deliverable in Round 4 is to formalize it as `playbooks/widget-contract.md`
with versioned JSON schemas. Round 6 codes against that doc.

Rough order:

0. **This scoping doc** (now) — locks the architecture, agent flow,
   event-sourcing model, and widget contract sketch.
1. **Round 1**: Duffel test orders → ships independently, low risk,
   reuses Round 20260512-130000 plumbing.
2. **Round 2**: Duffel Stays availability check → 1-day investigation,
   informs Round 4 hotel source.
3. **Round 3**: Firestore MCP + event sourcing + replay tooling → no
   UI yet, just storage + audit. Bigger than originally scoped.
4. **Round 4**: LLM-driven itinerary agent (hybrid input). First
   deliverable: formal widget contract doc. Then the agent.
5. **Round 6**: muno scaffold → starts in parallel with 4 once the
   widget contract doc lands (early in round 4).
6. **Round 5**: Google Calendar → after itinerary events exist to push.
7. **Round 7**: Tutorial → cap-stone, after 1-6 land.

Rounds 4 and 6 run in parallel once Round 3 is GREEN AND the widget
contract doc is approved. Rounds 5 and 7 strictly wait on prior rounds.

## What's NOT in this scoping

- Real-money booking (live Duffel token, payment processor, PCI). All
  Thread 3 territory.
- User authentication beyond "Guest". Firebase Auth round comes later.
- Hotel chains beyond Duffel Stays / Amadeus. Booking.com Demand API,
  Sabre, etc. — out of scope.
- Multi-language. English only for v1.
- Mobile native apps. Web-first; responsive is enough.
- Analytics / observability beyond what NoETL already emits.

## Related

- `sync/issues/2026-05-12-duffel-travel-api-integration.md` — Round
  20260512-130000 (Duffel search-only) shipped.
- `sync/issues/2026-05-12-google-places-travel-enrichment.md` — Pattern C
  enrichment AMBER.
- `sync/issues/2026-05-11-amadeus-test-api-500s.md` — Amadeus
  reliability tracker.
- `/Volumes/X10/projects/adiona/figma/Adiona_material/` — Figma exports.
- `https://www.figma.com/proto/jMHCnYMQ2dbfzu4ZsqfJCf/Adiona-material` —
  prototype.
- `git@github.com:noetl/muno.git` — empty UI repo awaiting bootstrap.
