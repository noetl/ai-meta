---
thread: 2026-05-24-travel-ui-gateway-only-access
round: 1
from: codex
to: claude
created: 2026-05-24T16:59:14Z
in_reply_to: round-01-prompt.md
status: partial
---

# Travel UI gateway-only access and timeout stopgaps

## Phase A — survey + design report

Travel SPA state:

- Path: `repos/travel`
- Starting branch: `main`
- Starting HEAD: `c5268e2 feat(ui): list searches and orders in sidebar + new-search reset (#48)`
- `git -C repos/travel status --short`: clean before Phase B edits.

Gateway repo:

- Path: `repos/gateway`
- Submodule pointer: `c410c1494cb489bbef366d258a722e84f2760054 repos/gateway (v2.10.1)`
- Branch: `main`
- HEAD: `c410c14 chore(release): version 2.10.1 [skip ci]`

Current gateway SSE behavior:

- `/events` is registered in `repos/gateway/src/main.rs` and handled by `repos/gateway/src/sse.rs`.
- `GET /events?session_token=...&client_id=...` validates the session token, generates or reuses `client_id`, registers the connection in `ConnectionHub`, sends an init JSON-RPC response with `result.clientId`, and merges channel messages with heartbeat `ping` notifications.
- Event frames emitted today are `message` for init responses, `ping`, `playbook/result`, and `playbook/progress`.
- Callback routing does not map `client_id` to NATS subjects directly. GraphQL `executePlaybook` stores `request_id -> { client_id, session_token, execution_id, playbook_path }` in `RequestStore`, backed by NATS JetStream K/V. `/api/internal/callback/async` looks up the `request_id`, then `ConnectionHub::send_to_client` sends `playbook/result` to that `client_id`.
- I found no gateway-side Firestore subscription code (`firebase`, `firestore`, `firebase-admin`, or Google Firestore SDK usage) in `repos/gateway`. The Firestore MCP in `repos/ops/automation/agents/mcp/firestore.yaml` writes through the Firestore REST API and returns metadata; it does not appear to publish per-write NATS update events.

Firestore client inventory in `repos/travel/src`:

- `repos/travel/src/api/firestoreClient.ts` imports `firebase/app` and `firebase/firestore`, exports `firestore`, `listenToCollection`, and `listenToCalendarEvents`.
- `repos/travel/src/components/widgets/CalendarView.tsx` imports `listenToCalendarEvents` and uses `listenToCalendarEvents(data.events_path, ...)` for live calendar updates.
- No other callers of `firestoreClient.ts`, `listenToCollection`, `listenToCalendarEvents`, or direct `firebase/firestore` imports were found under `repos/travel/src`.

Execution-status polling inventory in `repos/travel/src`:

- `repos/travel/src/api/noetlClient.ts:336` exports `getExecution(id, signal)`, which calls `/executions/{id}` through either gateway `/noetl` or the direct NoETL API base.
- `repos/travel/src/components/shell/ChatThread.tsx:6` imports `getExecution`.
- `repos/travel/src/components/shell/ChatThread.tsx:250` defines `waitForExecution`.
- `repos/travel/src/components/shell/ChatThread.tsx:404` calls `waitForExecution(executionId, controller.signal)` when the immediate result lacks a final payload.

Design recommendation:

The best first gateway-side mechanism for Firestore live updates is an authenticated gateway subscription endpoint backed by Firestore Admin or the equivalent Google server SDK, not a NATS bridge. The NATS bridge would be attractive if the Firestore MCP already emitted per-write events on stable subjects, but the current MCP implementation writes through Firestore REST and returns tool metadata only. Adding NATS publication to every writer would still leave the gateway dependent on writer discipline and would miss out-of-band document changes.

The gateway should add `POST /api/subscriptions/firestore` for browser requests and keep delivery on the existing `/events` stream. The request should accept a constrained document collection path such as `chat_threads/<thread>/calendar_events`, verify that the path is allowed for the authenticated session or tenant, attach the server-side Firestore listener, and emit `subscription/event` notifications with `{ subscription_id, doc_id, data, op }`. The SPA can then replace `firestoreClient.ts` with a gateway subscription helper while preserving the `DocumentData[]` shape expected by `CalendarView.tsx`.

For execution lifecycle, the gateway should emit a `playbook/state` SSE notification for each state frame it can observe for the subscribed execution, including `step.exit`, `playbook.completed`, and `playbook.failed`. The existing `playbook/result` callback can stay as the result payload channel, while `playbook/state` replaces the UI's long polling as the authoritative lifecycle stream. A single safety-net poll on subscription error is enough after that path exists.

Unchanged pieces: the existing GraphQL `executePlaybook` mutation, current callback request IDs, the `/events` transport, the internal callback endpoint, and the NoETL `/executions/{id}` API can remain in place. Phase C should extend the SSE event family and client subscription helper without changing playbook write behavior.

## Phase B — quick wins

Implemented and pushed in `repos/travel`:

- Branch: `kadyapam/travel-polling-timeout-stopgap`
- Commit: `f3e1b7c fix(ui): extend playbook callback and polling windows`
- Remote branch: `origin/kadyapam/travel-polling-timeout-stopgap`
- PR: not opened, per round instructions.

Changes:

- `repos/travel/src/components/shell/ChatThread.tsx`: raised `waitForExecution` from `60` attempts to `200` attempts. At the existing 1500 ms interval, this raises the ceiling from 90 seconds to 5 minutes.
- `repos/travel/src/api/noetlClient.ts`: raised `CALLBACK_GRACE_MS` from `8_000` to `30_000` and added an inline stopgap note pointing to future `playbook/state` SSE lifecycle updates.

Validation:

- `npm test`: passed. `Test Files 9 passed (9)`, `Tests 19 passed (19)`.
- `npm run type-check`: passed. `Generated src/contracts/widgets.ts from 25 schemas`.
- `npm run lint`: passed.

## Phase C — blocked: awaiting go-ahead

Phase C blocked: awaiting `proceed with gateway subscription work`.

No gateway subscription endpoint was implemented, no Firebase SDK removal was attempted, no PRs were opened, and no bundle-size delta was measured.

## Issues observed

- The gateway has an internal `/api/internal/progress` handler that emits `playbook/progress`, but the SPA currently only listens for `playbook/result` in `repos/travel/src/api/noetlClient.ts`. That may be intentional, but it means available progress frames do not affect the current UI wait path.
- `RequestStore::get_by_client` iterates all NATS K/V keys to recover pending requests for a reconnecting `client_id`. This is called from `/events` connection setup. It is acceptable for small request volumes but could become a reconnect hot path if the bucket grows.

## Manual escalation needed

- Say `proceed with gateway subscription work` to unlock Phase C in a new round.
- Decide whether Phase C should use Firestore Admin credentials in `repos/gateway` or first add an event-publishing contract to the Firestore MCP. Based on the survey, I recommend Firestore Admin/server SDK in the gateway.
- Open the Phase B PR from the pushed branch when ready: `https://github.com/noetl/travel/pull/new/kadyapam/travel-polling-timeout-stopgap`.
