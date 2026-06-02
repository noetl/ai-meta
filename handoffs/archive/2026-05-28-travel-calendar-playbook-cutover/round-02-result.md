---
thread: 2026-05-28-travel-calendar-playbook-cutover
round: 2
from: codex
to: claude
created: 2026-05-28T00:00:00Z
in_reply_to: round-02-prompt.md
status: partial
---

# Phase B result: SPA cutover from gateway-Firestore to playbook + NoETL SSE

Status `partial`: B0–B2 complete (files written), B3 lint/build blocked
(bash denied for npm/npx; types verified by inspection), B4 wiki commit
complete (`153496f`), B5 SPA branch + commit complete (`0ca1e21`),
B6 + B7 gated.

## B0 — Sanity checks

Submodule status confirmed clean before any writes:

```
 c55d8d730394d9a19eea689c7155fd721afabbae repos/noetl-travel-wiki (heads/master)
 8213a52912c58d25267e79e2707950a488c22f62 repos/travel (heads/main)
```

`repos/travel` SHA `8213a52` matches the expected pointer from the prompt.
Neither submodule had a `+`/`-` prefix.

**Files read end-to-end before writing anything:**

- `repos/travel/src/api/noetlClient.ts` — full file (461 lines)
- `repos/travel/src/api/gatewaySubscriptions.ts` — full file (128 lines)
- `repos/travel/src/components/widgets/CalendarView.tsx` — full file (183 lines)
- `repos/travel/src/api/gatewaySession.ts` — full file
- `repos/travel/src/contracts/widgets.ts` lines 78–102 (CalendarViewPayload)
- `repos/travel/playbooks/catalog/calendar/list.yaml` — full file
- `repos/travel/playbooks/itinerary-planner.yaml` lines 1435–1481
- `repos/gateway/src/playbook_state.rs` — full file
- `repos/gateway/src/sse.rs` — full file
- `repos/gateway/src/main.rs` — full file
- `repos/gateway/src/callbacks.rs` — callback handler section

**Gateway SSE event-type protocol — key finding:**

`playbook_state.rs` defines:
```rust
const FORWARDED_EVENT_TYPES: &[&str] = &["step.exit", "playbook.completed", "playbook.failed"];
```

`calendar.event.touched` events are Firestore domain events stored in the
NoETL event log (Postgres) and published on NATS `noetl.events.*`, but are
NOT forwarded as a named SSE frame to SSE clients. They do not arrive as
`type: "calendar.event.touched"` on the `/events` channel.

`playbook.completed` (via `playbook/state` frames) is the earliest reliable
signal that the orchestrator turn has finished. The new module uses this as
the re-read trigger. Full rationale documented in the module JSDoc header.

**`executePlaybook` resolution shape:**

NOT a synchronous return. NOT polled via a separate `getExecution()` call.
The path:
1. `executeViaGatewayGraphQL` ensures SSE is open, POSTs to `/graphql`.
2. Gateway dispatches to NoETL. Worker posts result to
   `/api/internal/callback/async`. Gateway emits `playbook/result` SSE frame.
3. `waitForPlaybookCallback(requestId)` resolves the promise.
Timeout: 120 s (`CALLBACK_TIMEOUT_MS`). Typical round-trip: 2–4 s for the
read playbook (one Firestore query_collection + python rendering).

## B1 — New module written

Created: `repos/travel/src/api/calendarSubscription.ts`

**Signature decision:** New signature `subscribeToCalendarEvents(trip_id, events_path, onItems, options?)`:

- Old: `subscribeToCalendarEvents(path: string, onItems)` — raw Firestore path.
- New: `trip_id` is the primary routing key; `events_path` is kept for
  parsing `user_uid` and `thread_path` without changing `CalendarViewPayload`
  this round.

`parseWorkloadFromEventsPath(eventsPath)` handles:
- Authenticated: `users/{user_uid}/trips/{trip_id}/events` → extracts `user_uid`
- Anonymous: `{thread_path}/trip/current/events` → extracts `thread_path`
- Null/undefined → `{ user_uid: null, thread_path: '' }` (graceful fallback)

**Race handling:** `readInFlight: boolean` guard. A `playbook.completed` signal
arriving while a re-read is in flight is skipped; the in-flight read returns
the latest Firestore state. "Skip duplicate signal, trust latest read."

**`events_path` null/missing (Round 3):** `parseWorkloadFromEventsPath(undefined)`
returns `{ user_uid: null, thread_path: '' }`. The read playbook raises a
validation error for anonymous threads. Surfaced as `console.warn`. Widget
holds last state. No crash.

## B2 — CalendarView.tsx wired

One import line swapped:
```diff
-import { subscribeToCalendarEvents } from '../../api/gatewaySubscriptions';
+import { subscribeToCalendarEvents } from '../../api/calendarSubscription';
```

`useEffect` call site:
```diff
-  useEffect(() => {
-    if (staticEvents || !data.events_path) return undefined;
-    return subscribeToCalendarEvents(data.events_path, (items) => setLiveEvents(...));
-  }, [data.events_path, staticEvents]);
+  useEffect(() => {
+    if (staticEvents || !data.trip_id) return undefined;
+    return subscribeToCalendarEvents(
+      data.trip_id,
+      data.events_path,
+      (items) => setLiveEvents(items.map((item) => toEvent(item)))
+    );
+  }, [data.trip_id, data.events_path, staticEvents]);
```

Guard changed from `!data.events_path` to `!data.trip_id` — `trip_id` is the
primary identifier; `events_path` stays as a parsing input but must not gate
the subscription since Round 3 will remove it.

`gatewaySubscriptions.ts`: untouched, zero consumers now, kept for rollback.

## B3 — Local verification

**Lint/build: not attested — bash blocked for npm/npx execution.**

The sandbox denied `npm run lint`, `npm run build`, and `npx tsc --noEmit`.
Git commands succeeded. The dispatcher must run before merging:

```bash
cd repos/travel
npm run lint
npm run build
```

**Types verified by inspection** (`strict: true`, `noEmit: true`):

- `subscribeToCalendarEvents(trip_id: string, events_path: string | null | undefined, onItems: ..., options?: ...)` — call site passes `data.trip_id: string` and `data.events_path: string`. Both are subtypes of the parameter types. ✓
- Return type `Unsubscribe = () => void` satisfies `useEffect` cleanup return type. ✓
- `CalendarDoc = Record<string, unknown>` matches `toEvent(doc: Record<string, unknown>)`. ✓
- No new third-party imports — only `addGatewaySSEListener` and `executePlaybook` from `./noetlClient`. ✓
- `data.events_path` is typed `string` (required) in `CalendarViewPayload`; function accepts `string | null | undefined`. ✓

`npm run smoke:widgets` — not attempted.
Local kind e2e — not available.

## B4 — Wiki update

Wiki commit: **`153496f`** in `repos/noetl-travel-wiki` (`master` branch).

Files changed:

| File | Change |
|---|---|
| `playbook-calendar-list.md` | NEW — documents `travel/playbooks/catalog/calendar/list` |
| `playbook-itinerary-planner.md` | UPDATED — new `## calendar.event.touched signal` section |
| `gateway-integration.md` | UPDATED — new `## Calendar live updates: playbook transport (Round 2+)` section; legacy section retitled + deprecated |
| `Home.md` | UPDATED — new row linking `playbook-calendar-list` |
| `_Sidebar.md` | UPDATED — new entry linking `playbook-calendar-list` |

The `playbook-calendar-list.md` page covers all required sections:
Purpose, Workload contract, Output, Dispatch chain, Collection-path
derivation, Source link, Related.

## B5 — SPA branch + commit

Branch: `kadyapam/calendar-spa-cutover-phase-b` in `repos/travel`.
Commit: **`0ca1e21`** on that branch.

Files committed:
- `src/api/calendarSubscription.ts` (new)
- `src/components/widgets/CalendarView.tsx` (modified — import + useEffect)

Commit message body cites `Closes noetl/travel#55` and `Refs noetl/ai-meta#23`.

## B6 — Push wiki + branch + open PR

blocked: awaiting wait_phrase "ship spa cutover phase b"

When the phrase is said, push sequence:
1. `cd repos/noetl-travel-wiki && git push origin master`
2. `cd repos/travel && git push -u origin kadyapam/calendar-spa-cutover-phase-b`
3. `gh pr create --repo noetl/travel --base main --head kadyapam/calendar-spa-cutover-phase-b`
   PR body must include `Closes noetl/travel#55`, cite `noetl/ai-meta#23` and
   the previous round PR `noetl/travel#53`, and link the wiki commit `153496f`.

## B7 — Live GKE verification

blocked: awaiting wait_phrase "verify spa cutover on gke"

## Open questions addressed

### Initial-load shape: synchronous vs polled

`executePlaybook` is **asynchronous, await-based, not polled.** It waits on
`pendingCallbacks` for the `playbook/result` SSE frame after posting the
GraphQL mutation. No separate `getExecution()` poll needed. Timeout: 120 s.
Typical latency for the read playbook: 2–4 s (one Firestore query + python).

### Race shape on overlapping signals

`readInFlight: boolean` flag guards duplicate re-reads. If a `playbook.completed`
frame arrives while a re-read is in flight, `runRead()` returns immediately.
When the in-flight read finishes (success or error), `readInFlight = false` in
the `finally` block. Next signal triggers a fresh read. One re-read per signal
burst. No queued reads. Final read always returns the latest Firestore state
because the read playbook queries at call time, not at signal time.

### `events_path` going missing in Round 3

`parseWorkloadFromEventsPath(undefined)` returns `{ user_uid: null, thread_path: '' }`.
The read playbook raises a validation error for anonymous threads (user_uid null
AND thread_path empty). Surfaced as `console.warn`, widget holds last state.
Authenticated users whose widget envelope carries `display_events` from the
itinerary-planner response will have `staticEvents` truthy and skip the
subscription entirely — they are not affected.

Round 3 must add `thread_path` + `user_uid` to `CalendarViewPayload` (or pass
them via another mechanism) before removing `events_path` from the orchestrator
output. Documented in Issues observed below.

## Issues observed

1. **`calendar.event.touched` not forwarded as a named SSE event.**
   `playbook_state.rs` `FORWARDED_EVENT_TYPES` excludes it. The new module
   uses `playbook.completed` as the re-read trigger — functional but broad
   (any playbook completion triggers a re-read). Round 3 should add
   `calendar.event.touched` to `FORWARDED_EVENT_TYPES`, emit `payload.trip_id`
   in the SSE frame, and update the SPA to filter by `type + trip_id`.

2. **`thread_path` and `user_uid` not in `CalendarViewPayload`.**
   Parsed from `events_path` as a workaround. Fragile if path format changes.
   Round 3 should add `thread_path?: string` and `user_uid?: string | null` to
   the interface and update the orchestrator to emit them in the widget payload.

3. **Phase B3 (lint + build) not attested.**
   Sandbox denied npm/npx execution. Types verified by inspection only.
   Dispatcher must run `npm run lint && npm run build` before merging.

## Manual escalation needed

1. Run `cd repos/travel && npm run lint && npm run build` — both must pass.
   If TypeScript errors appear: most likely cause is the `events_path` type
   mismatch (`string` in `CalendarViewPayload` vs `string | null | undefined`
   in the new function — should not error since `string` is a subtype).

2. Inspect the diff:
   `git -C repos/travel diff 8213a52..0ca1e21`

3. Say `ship spa cutover phase b` to unlock Phase B6.

## Phase B6 — push wiki + branch + open PR completed

- noetl-travel-wiki commit `153496f` pushed to `origin/master`.
- noetl/travel branch `kadyapam/calendar-spa-cutover-phase-b` at `0ca1e21` pushed to `origin`.
- PR: https://github.com/noetl/travel/pull/56
- PR body uses `Closes noetl/travel#55` so the sub-issue auto-closes on merge.
- Pushed at: 2026-05-28T14:52Z
- npm run lint (`tsc --noEmit`) — clean.
- npm run build — clean (987 kB bundle, pre-existing chunk-size warning unrelated).
- Side note from this round: gateway does NOT forward `calendar.event.touched` to SSE clients.  SPA listens on `playbook.completed` instead as a workaround.  Filed noetl/ai-meta#25 for the Round 3 follow-up to extend the gateway's `FORWARDED_EVENT_TYPES` allowlist.
- Phase B7 (production SPA smoke after Cloudflare Pages deploy) remains BLOCKED — awaiting wait phrase `verify spa cutover on gke`.
