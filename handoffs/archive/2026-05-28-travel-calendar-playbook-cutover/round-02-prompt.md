---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 2
from: claude
to: codex
created: 2026-05-28T15:15:00Z
status: open
expects_result_at: round-02-result.md
tracks: noetl/ai-meta#23
submodule_sub_issue: noetl/travel#55
wait_phrase: "ship spa cutover phase b"
predecessor: round-01-result.md
---

# Phase B: SPA cutover from gateway-Firestore subscription to playbook + NoETL SSE

> **Tracks:**
> - [noetl/ai-meta#23](https://github.com/noetl/ai-meta/issues/23) — umbrella.
> - [noetl/travel#55](https://github.com/noetl/travel/issues/55) — submodule sub-issue for this round. The PR must close it via the standard `Closes noetl/travel#55` keyword in its body.
>
> Round 1 (Phase A) shipped:
> - `travel/playbooks/catalog/calendar/list` v1 (the read playbook).
> - Orchestrator `muno/playbooks/itinerary-planner` v42 emits
>   `calendar.event.touched` after each successful Firestore
>   calendar-event write.
> - All live on GKE since 2026-05-28 ~14:00 UTC. Read path
>   verified end-to-end in Phase A6.
>
> Round 2 cuts the SPA over to the new transport so the existing
> `/api/subscriptions/firestore` path stops being called. This is
> the **destructive half** of the architectural fix.

## What changes (and what doesn't)

**Replaces:**
- `repos/travel/src/api/gatewaySubscriptions.ts` (the whole file
  is going away once the consumer is migrated).
- The single SPA call site:
  `repos/travel/src/components/widgets/CalendarView.tsx:25,89`
  (the `subscribeToCalendarEvents` import + invocation).

**With:**
- A new client module
  `repos/travel/src/api/calendarSubscription.ts` that:
  - On mount, calls `executePlaybook("travel/playbooks/catalog/calendar/list", { user_uid, trip_id, thread_path })`
    via the existing `noetlClient` API. Receives the
    `calendar_view` widget envelope's `display_events` from the
    response.
  - Subscribes to the gateway's existing NoETL SSE stream
    (`addGatewaySSEListener`, the same channel
    `gatewaySubscriptions.ts` used). Filters incoming events for
    `type: "calendar.event.touched"` with matching
    `payload.trip_id`. On each match, re-runs the read playbook
    and replaces the local list.
  - Returns an `Unsubscribe` function shape identical to what
    `subscribeToCalendarEvents` returned today, so
    `CalendarView.tsx` only changes one import line.

**Untouched:**
- Anything else under `repos/travel/src/`.
- The gateway code (`/api/subscriptions/firestore` POST + DELETE
  routes still exist server-side — that's Round 3 work).
- The orchestrator playbook (already shipped in Round 1).
- The read playbook (already shipped in Round 1).
- `repos/ops/` (no helm / config change needed for Phase B —
  the orchestrator already emits, the gateway already
  multicasts NoETL events on its SSE channel).

## Live emit verification rides along

Phase A6 deferred live verification of `calendar.event.touched`
because no executions had run against the v42 orchestrator yet
and the SPA still routed to an older catalog version. Phase B
is the natural place to confirm the emit works end-to-end:
once the SPA refactor lands and the first user-driven chat turn
appends a calendar event, the new SSE-listener path either
fires (✓) or it doesn't (📛 — surface as an issue against
Phase A2's emit code).

## Where to operate

- `repos/travel/src/` only. Branch off `main`:
  `kadyapam/calendar-spa-cutover-phase-b`.
- Latest `repos/travel` main is at SHA `8213a52` (Phase A merge).
  Confirm via `git submodule status repos/travel` from ai-meta
  root.

## Phases

### Phase B0 — sanity checks (no remote writes)

1. Confirm submodule sync (`git submodule status repos/travel`
   shows no `+`/`-` prefix, SHA matches `8213a52`).
2. Read the **whole** of these files end-to-end before writing
   anything — Round 2 only succeeds if the new module fits the
   existing transport idioms:
   - `repos/travel/src/api/noetlClient.ts` — what
     `executePlaybook(path, workload, options)` already does
     (look at the signature around line 425; auth-aware,
     handles both gateway and direct modes).
   - `repos/travel/src/api/noetlClient.ts:130–200` — the SSE
     connection management
     (`addGatewaySSEListener`, `ensureGatewaySSE`); we'll reuse
     the same channel `subscribeToCollection` does today.
   - `repos/travel/src/api/gatewaySubscriptions.ts` — the API
     contract we're matching for backwards compat. Pay
     particular attention to:
     - The `Unsubscribe` return type (cleanup contract).
     - How it currently passes `signal: AbortSignal` and
       `scope: 'owner'`.
     - Its event parsing in `parseSubscriptionEvent` — the new
       module needs an analogous parser for NoETL `calendar.event.touched`
       events.
   - `repos/travel/src/components/widgets/CalendarView.tsx`
     end-to-end — note how `data.events_path` is passed today,
     whether `data.trip_id` is also available on the widget
     payload (it is — per the `CalendarViewPayload` interface
     at `repos/travel/src/contracts/widgets.ts:81–87`).
   - `repos/travel/src/api/gatewaySession.ts` —
     `getGatewayBaseUrl()` + token handling, in case the new
     module needs them.
3. Capture the NoETL event shape `calendar.event.touched`
   travels over the gateway SSE. The orchestrator emit (from
   Phase A2, in `repos/travel/playbooks/itinerary-planner.yaml`
   around line 1442) produces:
   ```python
   {
       "thread_path": thread_path,
       "event": {
           "type": "calendar.event.touched",
           "payload": {
               "trip_id": trip_id,
               "user_uid": uid_for_event,
               "thread_path": thread_path,
               "event_id": cal_evt.get("event_id"),
               "op": "added",
           },
           "actor": {"kind": "agent", "name": "muno-itinerary-planner"},
       },
   }
   ```
   By the time it lands on the gateway SSE stream, it's wrapped
   in whatever envelope the existing SSE listener uses (the
   current `subscription/event` shape from `gatewaySubscriptions.ts`
   is **not** what NoETL events look like — check the gateway
   SSE protocol by greping `repos/gateway/src/sse.rs` for the
   event-type names, or run a smoke and watch the network tab).

### Phase B1 — write the new module (no remote writes)

4. Create `repos/travel/src/api/calendarSubscription.ts` with
   exports `subscribeToCalendarEvents(trip_id, thread_path,
   user_uid, onItems, options)`.

   Function behavior:
   - On call: invoke
     `executePlaybook("travel/playbooks/catalog/calendar/list",
     { trip_id, thread_path, user_uid })` (the same
     `executePlaybook` `CalendarView.tsx` already imports via
     `ChatThread.tsx`). Wait for completion.
     The response carries the widget envelope; extract
     `display_events` and feed them to `onItems(...)` in
     `CalendarEvent[]` shape (use the same `toEvent(doc)`
     transform `CalendarView.tsx` does today, or duplicate
     enough of it to keep the public API intact).
   - Subscribe to the NoETL SSE channel (the existing
     `addGatewaySSEListener` API). Filter for the
     `calendar.event.touched` event-type with matching
     `payload.trip_id`. On each match, re-run the read playbook
     and re-emit the new full list via `onItems(...)`.
   - Return an `Unsubscribe` function that removes the SSE
     listener and aborts any in-flight playbook execution
     (`AbortController`).

5. Keep the public function signature **identical** to the
   existing `subscribeToCalendarEvents(path, onItems)` in
   `gatewaySubscriptions.ts` IF possible — the consumer in
   `CalendarView.tsx` shouldn't need anything more than an
   import-path swap. The new signature MAY need to accept
   `trip_id` + `thread_path` + `user_uid` separately (the
   widget already has all three on its payload), in which case
   change the import call site too. Pick whichever is cleaner;
   document the decision in the report.

6. **Do NOT delete `gatewaySubscriptions.ts` in this round.**
   Leave it un-imported (it'll be dead code after the
   `CalendarView.tsx` swap). Round 3 (gateway code removal)
   will delete it from the SPA side at the same time it deletes
   the `/api/subscriptions/firestore` route from the gateway —
   that way operators can roll back Round 2 independently if
   needed.

### Phase B2 — wire the consumer (no remote writes)

7. In `repos/travel/src/components/widgets/CalendarView.tsx`:
   - Replace the import:
     `import { subscribeToCalendarEvents } from '../../api/gatewaySubscriptions'`
     → `from '../../api/calendarSubscription'`.
   - Replace the `useEffect` call site (line 89) to pass the
     fields the new module needs (`data.trip_id`,
     `data.events_path` is no longer needed if the new module
     derives the path itself from `trip_id` + `thread_path` —
     the read playbook does that derivation, so the SPA can
     drop it).
   - Do **NOT** remove the `events_path` field from the widget
     payload shape (the playbook still emits it; deletion is
     Round 3 work).

### Phase B3 — local verification (no remote writes)

8. From `repos/travel`:
   ```
   npm run lint
   npm run build
   ```
   Both must pass. Capture last 20 lines of output in the
   report.
9. Run the existing widget-contract smoke if it exists:
   `npm run smoke:widgets`. Capture output.
10. If a local kind cluster is available (`noetl context list`
    shows a working `kind-cluster` entry), run a local
    end-to-end:
    - Start the SPA dev server (`npm run dev`).
    - Drive a chat turn that triggers the `calendar_live`
      intent (e.g. confirm a flight selection).
    - Confirm the calendar widget populates from the read
      playbook (not from `/api/subscriptions/firestore`).
    - Confirm a subsequent chat turn that appends a calendar
      event triggers a re-read via the SSE signal.
    Skip cleanly if kind is unavailable; document in the
    report.

### Phase B4 — wiki update (no remote writes)

> Per `agents/rules/wiki-maintenance.md` Rule 2b, every handoff
> round closes with a wiki update.  This round covers a debt from
> Round 1 (the new read playbook never got its wiki page) AND the
> Round 2 SPA-side change.  Do both in one wiki commit.

11. Operate in `repos/noetl-travel-wiki/` (it's the travel wiki
    submodule pre-cloned into the repo).  Pages that already
    exist:
    `Home.md`, `_Sidebar.md`, `adapting-for-your-domain.md`,
    `architecture.md`, `auth-and-session.md`, `deployment.md`,
    `gateway-integration.md`, `playbook-itinerary-planner.md`,
    `widget-contract.md`.

12. Create `repos/noetl-travel-wiki/playbook-calendar-list.md`
    documenting the new read playbook
    `catalog://travel/playbooks/catalog/calendar/list`.
    Required sections:
    - **Purpose**: read calendar events for a trip and return a
      pre-rendered `calendar_view` widget envelope.  Used by the
      SPA on widget mount + after every `calendar.event.touched`
      signal.
    - **Workload contract**:
      `{trip_id, user_uid, thread_path}` — what each field means
      and which is required when.
    - **Output**: the `calendar_view` envelope shape
      (`schema_version: 1`, fields per
      `CalendarViewPayload` in `widget-contract.md`).
    - **Dispatch chain**: which MCP it calls (`firestore_mcp`,
      tool `query_collection`) and where (`automation/agents/mcp/firestore`).
    - **Collection-path derivation**: the conditional from the
      orchestrator (authenticated user vs anonymous thread).
    - **Source link** to the playbook YAML in
      `noetl/travel@main`.
    - **Related**: cross-link to
      `playbook-itinerary-planner.md` (which writes calendar
      events) and `widget-contract.md` (calendar_view).

13. Update `repos/noetl-travel-wiki/playbook-itinerary-planner.md`:
    add a new section documenting the
    `calendar.event.touched` event the orchestrator now emits
    after each successful Firestore calendar-event write.
    Include the payload shape (`trip_id`, `user_uid`,
    `thread_path`, `event_id`, `op`).  Note that the event is
    the signal SPA subscribers use to know the calendar
    needs re-reading.

14. Update either `repos/noetl-travel-wiki/architecture.md`
    or `repos/noetl-travel-wiki/gateway-integration.md` (whichever
    is the better fit — read both first) to document the new
    SPA transport for calendar updates: the SPA reads via
    `executePlaybook` against the read playbook, then listens
    to the NoETL SSE channel for `calendar.event.touched`
    signals to trigger re-reads.  Explicitly call out that the
    old `/api/subscriptions/firestore` transport is being
    phased out in Round 3.

15. Update `repos/noetl-travel-wiki/Home.md` and
    `repos/noetl-travel-wiki/_Sidebar.md` to link the new
    `playbook-calendar-list.md` page.

16. Commit the wiki changes in `repos/noetl-travel-wiki/` —
    standalone commit, not part of the SPA branch:
    ```
    cd repos/noetl-travel-wiki
    git add playbook-calendar-list.md playbook-itinerary-planner.md \
            architecture.md gateway-integration.md Home.md _Sidebar.md
    git -c commit.gpgsign=false commit -m "$(cat <<EOF
    wiki(travel): document calendar.list read playbook + calendar.event.touched emit + SPA cutover transport

    Closes the wiki debt from noetl/ai-meta#23 Round 01 + ships
    the Round 02 SPA-cutover wiki update in one commit, per
    agents/rules/wiki-maintenance.md Rule 2b.

    Refs noetl/ai-meta#23
    Refs noetl/travel#54
    Refs noetl/travel#55
    EOF
    )"
    ```
    Do NOT push the wiki commit yet — the dispatcher pushes both
    the wiki AND the SPA PR together after review.

### Phase B5 — commit the SPA changes (no remote writes)

17. From `repos/travel`:
    ```
    git checkout -b kadyapam/calendar-spa-cutover-phase-b
    git add src/api/calendarSubscription.ts \
            src/components/widgets/CalendarView.tsx
    git -c commit.gpgsign=false commit -m "$(cat <<EOF
    feat(spa): route calendar live-updates through playbook + NoETL SSE (Phase B)

    Replaces ``subscribeToCalendarEvents`` from
    ``gatewaySubscriptions.ts`` with a new
    ``calendarSubscription.ts`` that:

    - Reads via ``catalog://travel/playbooks/catalog/calendar/list``
      (the Phase A read playbook), so the SPA no longer hits
      ``/api/subscriptions/firestore`` for the initial load.
    - Listens to the existing NoETL SSE channel for
      ``calendar.event.touched`` events, filters by trip_id,
      re-reads on signal.  Replaces the gateway-Firestore
      subscription transport with the
      gateway-as-gatekeeper-only transport mandated by
      ``agents/rules/execution-model.md``.

    ``gatewaySubscriptions.ts`` is left in tree (no consumer
    now) for one round to give operators a rollback path.
    Round 3 (gateway code removal) deletes it alongside the
    server-side ``/api/subscriptions/firestore`` route in
    ``repos/gateway/src/firestore_subscriptions.rs``.

    Wiki update for both the new read playbook + this SPA
    cutover shipped in noetl-travel-wiki (see ai-meta result
    file for the wiki SHA).

    Closes noetl/travel#55
    Refs noetl/ai-meta#23
    EOF
    )"
    ```
18. Do NOT push. The dispatcher will review the diff before
    green-lighting Phase B6.

### Phase B6 — push wiki + branch + open PR

> ***Run only after explicit human go-ahead. Wait phrase: `ship spa cutover phase b`.***

19. Push the wiki commit first:
    `cd repos/noetl-travel-wiki && git push origin master`
20. Push the SPA branch:
    `cd repos/travel && git push -u origin kadyapam/calendar-spa-cutover-phase-b`
21. Open the SPA PR with
    `gh pr create --repo noetl/travel --base main --head kadyapam/calendar-spa-cutover-phase-b`.
    Body must:
    - Use `Closes noetl/travel#55` so the sub-issue auto-closes on merge.
    - Cite the umbrella `noetl/ai-meta#23`.
    - Cite the previous round's PR `noetl/travel#53`.
    - Link the handoff prompt + result file paths under `noetl/ai-meta`.
    - Link the wiki commit SHA from `noetl-travel-wiki`.
22. Print both the PR URL and the wiki commit SHA.

### Phase B7 — live verification on staging / GKE

> ***Run only after explicit human go-ahead. Wait phrase: `verify spa cutover on gke`.***

23. After the PR merges and the SPA is rebuilt + deployed
    (Cloudflare Pages takes ~30 seconds for the new build),
    drive a "trip to paris" SPA flow against the production
    gateway. Confirm:
    - The calendar widget populates with `display_events` from
      the read playbook (check network tab for a
      `POST /noetl/execute` to
      `travel/playbooks/catalog/calendar/list`, not a
      `POST /api/subscriptions/firestore`).
    - A chat turn that appends a new calendar event triggers
      a re-fetch (second `POST /noetl/execute` to the same
      playbook).
    - The orchestrator emitted at least one
      `calendar.event.touched` event for that execution (check
      `noetl.event` for entries with that type in the relevant
      `execution_id`).
24. If the trip-to-paris flow is blocked because
    noetl/ai-meta#24 isn't merged yet (the Duffel
    search_offers tool still fails), use a different
    SPA-triggerable path that appends a calendar entry
    without depending on Duffel — e.g. confirming a hotel
    selection from a static hotel list, if the orchestrator
    supports that. Document whatever you do.

## FINAL REPORT

Same shape as Round 01's result file. Write to
  handoffs/active/2026-05-28-travel-calendar-playbook-cutover/round-02-result.md
with frontmatter `in_reply_to: round-02-prompt.md`. One H2 per
phase + standard sections.

## Hard rules for this thread

- Never push to `origin/main` on any repo. Phases B5 and B6 are
  explicitly gated.
- Never force-push.
- Never merge PRs yourself.
- Do not touch `repos/gateway/` in this round — Round 3 owns
  that.
- Do not delete `gatewaySubscriptions.ts` in this round (see
  Phase B1 step 6).
- Do not remove `events_path` from the widget envelope or the
  playbook output — the field stays as the
  Firestore-collection-path hint until Round 3.
- Public-safety: ai-meta is a public repo. No session tokens
  or Auth0 IDs in the result body.
- If preconditions aren't met (e.g. local kind unavailable,
  build fails on master), stop and report — don't improvise.

## Open questions to address in the report

- **Initial-load shape.** Does
  `executePlaybook("travel/playbooks/catalog/calendar/list", ...)`
  return synchronously with the rendered widget envelope, or
  does it return an execution-id and require a separate
  `getExecution()` poll? Check `noetlClient.ts` and document
  the path you used.
- **Race shape.** If a `calendar.event.touched` event arrives
  while a re-read is in flight, what happens? Document the
  approach (debounce / cancel previous / serialise).
- **`events_path` is still in the widget payload from the
  orchestrator.** Round 3 will drop it. Confirm the new
  module ignores it cleanly (doesn't fail if it's null or
  missing in Round 3 when the field goes away).
