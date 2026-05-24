---
thread: 2026-05-24-travel-ui-gateway-only-access
round: 1
from: claude
to: codex
created: 2026-05-24T17:05:00Z
status: open
expects_result_at: round-01-result.md
---

# Travel UI: enforce gateway+playbook-only data access + fix polling/grace timeouts

> **Predecessor:** Production incident
> `memory/inbox/2026/05/20260524-163936-production-auth-travel-login-incident-cluster-side-mitigatio.md`
> (or its compaction successor). User reports
> `Execution 633631566496792709 did not complete in time` from
> https://travel.mestumre.dev and 500 from
> https://gateway.mestumre.dev. Cluster-side mitigations already
> applied: gateway `AUTH_PLAYBOOK_TIMEOUT_SECS` 12→60, Helm
> `worker.autoscaling.minReplicas` 1→3 (release rev 157). This
> thread closes the front-end gaps.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md` and `agents/rules/handoffs.md` first. Code
changes land in `repos/travel` (the SPA) and possibly `repos/gateway`
(the Rust gateway between the SPA and noetl-server).

## Context

Three problems in the travel UI / gateway boundary surfaced during
the incident triage. They are independent but related.

### 1. UI reads Firestore directly (violates architecture)

`repos/travel/src/api/firestoreClient.ts` imports
`firebase/firestore` and creates a Firestore client at module
scope. Two helpers, `listenToCollection` and `listenToCalendarEvents`,
use `onSnapshot` to subscribe to Firestore documents straight from
the browser. `CalendarView.tsx:89` uses
`listenToCalendarEvents(data.events_path, …)` to drive live calendar
updates. The SPA ships `VITE_FIREBASE_API_KEY` in its build env.

User architecture principle: **the UI must not access the database
directly — only through the gateway, which routes everything via
playbooks.** All Firestore *writes* already honor this (every
`persist_*` / `append_*` playbook step uses
`tool: agent → automation/agents/mcp/firestore`). The *reads* via
`onSnapshot` are the violation.

The gateway already exposes an SSE channel at `GET /events` (see
`repos/travel/src/api/noetlClient.ts:115` — `connectSSE`). The UI
already subscribes for `playbook/result` callback frames. Routing
Firestore live updates through that same SSE channel — pushed
from the gateway after the gateway subscribes to Firestore on the
server side — is the natural place to land this.

### 2. ChatThread `waitForExecution` 90s polling ceiling

`repos/travel/src/components/shell/ChatThread.tsx:250-262`:

```typescript
async function waitForExecution(executionId: string, signal: AbortSignal): Promise<unknown> {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    await abortableDelay(1500, signal);
    const execution = await getExecution(executionId, signal);
    const status = String((execution as Record<string, unknown>)?.status || '').toLowerCase();
    if (status === 'completed' || status === 'succeeded') return execution;
    if (status === 'failed' || status === 'error' || status === 'cancelled') {
      if (hasFinalPayload(execution)) return execution;
      throw new Error(extractExecutionError(execution, executionId, status));
    }
  }
  throw new Error(`Execution ${executionId} did not complete in time`);
}
```

60 attempts × 1500ms = **90s ceiling**. Healthy itinerary-planner
runs are ~10s, but legitimate cold-paths can exceed 90s. The
incident showed a real execution taking 10m24s while the UI showed
the timeout error after 90s. Even with the cluster-side fixes,
this ceiling is too tight.

### 3. `CALLBACK_GRACE_MS = 8_000` and dual completion paths

`repos/travel/src/api/noetlClient.ts:17-18`:

```typescript
const CALLBACK_TIMEOUT_MS = 120_000;
const CALLBACK_GRACE_MS = 8_000;
```

Used at `noetlClient.ts:303`:

```typescript
return await waitForPlaybookCallback(requestId, signal, executionId ? CALLBACK_GRACE_MS : CALLBACK_TIMEOUT_MS);
```

When the gateway returns an `executionId` immediately, the UI waits
only **8s** for the `playbook/result` SSE frame before falling
back to polling (which then hits the 90s ceiling above).

This 8s grace exists because playbooks that don't call
`/api/internal/callback` themselves (e.g. the itinerary-planner)
never trigger the SSE frame — so the UI gives up fast and falls
through to polling. But for playbooks that DO call back, an 8s
window is too short under transient cluster contention; the
callback arrives, the UI is already polling, and the SSE frame
gets discarded (no resolver in `pendingCallbacks`).

A better design: the gateway pushes execution-state changes
(`step.exit`, `playbook.completed`, `playbook.failed`) over the
same SSE channel for any execution the UI subscribed to. The UI
treats SSE as authoritative and never polls.

## Background

### Files / paths

- SPA root: `repos/travel/`
- SPA env (build-time): `repos/travel/.env.example`
- Firestore client: `repos/travel/src/api/firestoreClient.ts`
- Gateway client (callbacks + GraphQL): `repos/travel/src/api/noetlClient.ts`
- Gateway session/auth client: `repos/travel/src/api/gatewaySession.ts`
- Chat polling loop: `repos/travel/src/components/shell/ChatThread.tsx`
- Calendar live-listener consumer: `repos/travel/src/components/widgets/CalendarView.tsx`
- Gateway repo: `repos/gateway/` (or wherever the Rust gateway lives
  — check submodules)
- Existing gateway SSE handler (server side): grep for
  `/events` route, `EventSource` semantics. The gateway env shows
  `NATS_UPDATES_SUBJECT_PREFIX=playbooks.executions.` and
  `GATEWAY_HEARTBEAT_INTERVAL_SECS` and
  `GATEWAY_CONNECTION_TIMEOUT_SECS=300`, so server-side SSE state
  exists.

### Cluster state already in place

- Gateway env `AUTH_PLAYBOOK_TIMEOUT_SECS=60` (was 12).
- Helm `worker.autoscaling.minReplicas=3` (was 1), Helm release
  revision `157`.
- KEDA chart-templated `ScaledObject` is the only autoscaler
  (post-ops #116).

These are operational fixes; this thread is the client-side fix
that closes the UX gap.

### What success looks like

- The Firebase SDK is gone from the SPA bundle. The SPA reads
  calendar live-updates through the gateway. The user's
  architecture principle holds: no direct database access from
  the browser.
- The UI never throws `"Execution {id} did not complete in time"`
  for an execution that completed under a sane ceiling (≥ 5 min).
- The 8s grace is replaced with a real subscription model: the UI
  trusts gateway SSE pushes and only polls as a safety net (or
  not at all).
- The travel SPA bundle no longer includes the `firebase` npm
  dependency.

## Phases

### Phase A — survey + design report (no remote writes)

1. `git -C repos/travel status --short && git -C repos/travel log --oneline -5`
2. `git -C repos/travel branch --show-current`
3. Identify the gateway repo path. Either `repos/gateway`,
   `repos/noetl-gateway`, or another. Confirm submodule pointer and
   current branch:
   ```
   git submodule status | grep -i gateway
   git -C <gateway-repo> log --oneline -5
   ```
4. Read the existing gateway SSE handler (`/events` route) and
   document:
   - What event frames it emits today (only `playbook/result`?
     anything else?).
   - How it maps `client_id` to NATS subjects.
   - Whether it already subscribes to Firestore on the server
     side anywhere (firebase-admin or via `mcp/firestore`).
5. Inventory all callers of `firestoreClient.ts` exports
   (`firebase`, `firestore`, `listenToCollection`,
   `listenToCalendarEvents`). Use `rg` in `repos/travel/src`.
6. Inventory all polling sites that look at execution status, not
   just `ChatThread.waitForExecution`. Run
   `rg -n "getExecution|/api/executions" repos/travel/src`.
7. Produce a short **design section** in the result file (2–4
   paragraphs) covering:
   - The proposed gateway-side change to deliver Firestore live
     updates over the existing SSE channel. Two options:
     **(i)** gateway subscribes to NATS subjects matching the
     `mcp/firestore.append_event` pattern and re-emits to the
     SSE client; **(ii)** gateway uses `firebase-admin` directly
     to attach `onSnapshot` listeners scoped to the authenticated
     user's threads, and forwards to SSE. Recommend one.
   - The proposed `playbook/state` (or similar) SSE frame the
     gateway emits for every `step.exit` / `playbook.completed`
     event on subscribed executions, replacing the polling.
   - What stays unchanged.

### Phase B — quick wins (cluster-safe, ship-now)

These are low-risk client-side changes that improve the symptom
even before the gateway work in Phase C lands. They run
unattended.

8. In `repos/travel/src/components/shell/ChatThread.tsx`:
   - Bump `waitForExecution` ceiling from 60 attempts to 200
     (= 5 min at 1500ms) **OR** parameterize by playbook path.
     The intent is to never throw `did not complete in time` for
     legitimate runs.
   - Optional: when the SSE callback fires while polling is
     active, prefer the SSE result and short-circuit the poll.
9. In `repos/travel/src/api/noetlClient.ts`:
   - Raise `CALLBACK_GRACE_MS` from `8_000` to **`30_000`** as an
     interim. Document inline that this is a stopgap until the
     gateway emits `playbook/state` updates and the polling
     fallback can be removed.
10. Run the SPA's existing tests / type-check (whatever the repo
    has — `npm test`, `npm run typecheck`, `npm run lint`).
11. Commit the Phase B changes on a feature branch like
    `kadyapam/travel-polling-timeout-stopgap` in
    `repos/travel`. **Do not open the PR yet** — Phase C either
    extends this branch or supersedes it.

### Phase C — gateway-side subscription endpoint

> ***Run only after explicit human go-ahead. Wait phrase: `proceed with gateway subscription work`.***

This phase implements the gateway-side subscription and the SPA
changes that consume it.

12. In the gateway repo, add an authenticated SSE event family for
    document subscriptions. Suggested shape:
    - `POST /api/subscriptions/firestore` with body
      `{ "path": "chat_threads/<thread>/calendar_events", "scope": "..." }`
      returns `{ "subscription_id": "..." }`.
    - The same SSE channel `/events` now emits frames of type
      `subscription/event` with payload
      `{ "subscription_id": "...", "doc_id": "...", "data": {...}, "op": "added|modified|removed" }`.
    - Subscriptions are user-scoped via the session token. The
      gateway verifies the requested path is under the user's
      tenant before opening the listener.
13. Two server-side options for the Firestore listener (pick one
    in Phase A's design report and execute it here):
    - **(i) NATS bridge:** gateway subscribes to the NATS subject
      the firestore MCP emits when it writes. Simpler if the MCP
      already emits per-write events on NATS.
    - **(ii) firebase-admin:** gateway holds an admin Firestore
      handle and attaches `onSnapshot` server-side for each
      subscription. Cost: one Firestore connection per
      subscription pod, one admin credential to manage.
14. In the SPA (`repos/travel/src/api`):
    - Replace `firestoreClient.ts` exports with a new
      `gatewaySubscriptions.ts` that opens an SSE-backed
      subscription via the gateway and yields the same shape
      (`DocumentData[]`) `CalendarView.tsx` expects.
    - Remove `firebase` from `package.json` dependencies. Remove
      `VITE_FIREBASE_API_KEY`, `VITE_FIREBASE_AUTH_DOMAIN`,
      `VITE_FIREBASE_PROJECT_ID` from `.env.example` and any
      build configuration. Confirm the SPA bundle no longer
      contains `firebase` artifacts (`npm run build` then
      `grep -r firebase dist/`).
15. After the subscription path works:
    - In `ChatThread.tsx`, switch `waitForExecution` to subscribe
      to `subscription/event` frames keyed by execution_id (or
      to `playbook/state` frames if the gateway emits those for
      execution lifecycle). Remove the 200-attempt polling loop;
      keep a single safety-net poll on subscription error.
    - In `noetlClient.ts`, remove or repurpose
      `CALLBACK_GRACE_MS` once polling no longer exists.

16. Tests: add a Vitest/jest test (or whatever the SPA uses) that
    exercises the gateway subscription path with a mock SSE
    server. Add a gateway integration test for the
    `POST /api/subscriptions/firestore` flow.

17. Commit the Phase C changes; open a single PR per repo (one
    for `repos/travel`, one for the gateway repo). **Do not
    merge.** Link both PRs in the result.

### Phase D — write result

18. Write the report at
    `handoffs/active/2026-05-24-travel-ui-gateway-only-access/round-01-result.md`.

    Required sections:

    ```markdown
    ## Phase A — survey + design report
    ## Phase B — quick wins
    ## Phase C — gateway subscription (or "blocked: awaiting go-ahead")
    ## Issues observed
    ## Manual escalation needed
    ```

    Include:
    - Gateway repo path, submodule SHA, branch.
    - Inventory of `firestoreClient.ts` callers.
    - Inventory of execution-status polling sites.
    - Chosen subscription mechanism and rationale.
    - PR URLs (if Phase C ran).
    - Bundle-size delta after `firebase` removed (if Phase C
      ran).

19. Commit + push the result.

## Hard rules for this thread

- Do not run `noetl_gke_fresh_stack.yaml --set action=provision`.
- Do not merge any PR opened in this round. Open them; link them;
  stop.
- Do not store secrets (no Firebase API keys, no Auth0 secrets,
  no service-account JSON) in any file under `ai-meta`. This
  repo is public.
- Do not force-push on any branch.
- Phase C is gated behind the wait phrase
  `proceed with gateway subscription work`. If the user hasn't
  said it in chat by the time you reach Phase C, write the
  result with `Phase C blocked: awaiting "proceed with gateway
  subscription work"` and stop.
- Respect `AGENTS.md`, `agents/rules/handoffs.md`, and
  `agents/rules/writing-style.md` (no "canonical" in prose).
- If you discover an unrelated production-impacting bug while
  surveying (separate from the three listed problems), flag it
  in "Issues observed" but do not fix it in this round.

## What stays in scope

- Travel SPA polling/timeout/grace constants.
- Travel SPA Firestore access removal.
- Gateway subscription endpoint and SSE frame extension.

## What is explicitly out of scope

- Worker concurrency / per-step latency in `repos/noetl`.
- `/api/executions` listings stale-status bug in noetl-server.
- Itinerary-planner playbook step consolidation.
- Any infra changes (KEDA, Helm, GKE).

Those three items will land as separate handoffs.
