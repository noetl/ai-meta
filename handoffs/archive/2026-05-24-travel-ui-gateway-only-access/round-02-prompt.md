---
thread: 2026-05-24-travel-ui-gateway-only-access
round: 2
from: claude
to: codex
created: 2026-05-24T17:35:00Z
status: open
expects_result_at: round-02-result.md
---

# Phase C go-ahead — gateway subscription endpoint + remove Firebase SDK from SPA

> **Predecessor:** `round-01-result.md` in this same thread. Phase A
> (survey + design) and Phase B (timeout stopgaps) are complete.
> Phase B PR open at <https://github.com/noetl/travel/pull/49>
> (do not merge from this round).

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`, and
`agents/rules/writing-style.md` (no "canonical" in prose) first.

## Wait phrase

***proceed with gateway subscription work*** — given. Phase C is
authorized.

## Context recap

Round 01 established:

- Travel SPA reads Firestore directly via `firebase/firestore`
  `onSnapshot` in `repos/travel/src/api/firestoreClient.ts`, used
  by `CalendarView.tsx:89`. This bypasses the
  gateway+playbook contract.
- Gateway repo `repos/gateway` at `c410c14` (v2.10.1) emits
  `playbook/result`, `playbook/progress`, `ping`, and init
  `message` frames over SSE at `GET /events`.
- No gateway-side Firestore code today. MCP at
  `repos/ops/automation/agents/mcp/firestore.yaml` writes via REST
  and does not emit NATS events.
- Recommended design: gateway adds `POST /api/subscriptions/firestore`
  + a Firestore Admin server-side listener, and emits
  `subscription/event` frames over the existing `/events` channel.
  Also: gateway emits a new `playbook/state` SSE family for
  execution lifecycle events so the SPA can stop polling.

## What this round delivers

1. Gateway-side subscription endpoint at
   `POST /api/subscriptions/firestore`, backed by Firestore Admin
   server-side listeners scoped to the authenticated session.
2. New SSE frame family `subscription/event` for Firestore live
   updates.
3. New SSE frame family `playbook/state` for execution lifecycle
   updates (`step.exit`, `playbook.completed`, `playbook.failed`).
4. SPA migration off `firebase/firestore`:
   - Replace `firestoreClient.ts` with `gatewaySubscriptions.ts`
     using SSE.
   - Drop `firebase` from `package.json`.
   - Drop `VITE_FIREBASE_*` from `.env.example` and any build
     config.
5. SPA migration off the `waitForExecution` polling loop:
   - Subscribe to `playbook/state` for the active execution.
   - Keep a single safety-net poll on subscription error only.
6. One PR per repo: `repos/gateway` and `repos/travel`. Do not
   merge either.
7. Result file at
   `handoffs/active/2026-05-24-travel-ui-gateway-only-access/round-02-result.md`.

## Phases

### Phase A — confirm starting state

1. Sync submodules:
   ```
   git -C repos/travel fetch origin && git -C repos/travel checkout main && git -C repos/travel pull --ff-only origin main
   git -C repos/gateway fetch origin && git -C repos/gateway checkout main && git -C repos/gateway pull --ff-only origin main
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only origin main
   ```
2. Confirm Phase B branch state in `repos/travel`:
   `git -C repos/travel branch -a | grep travel-polling-timeout-stopgap`.
   Confirm <https://github.com/noetl/travel/pull/49> exists and is
   open. Phase C extends this branch (do not start from a fresh
   branch); name the Phase C commits as additional commits on
   `kadyapam/travel-polling-timeout-stopgap`.
3. Open a fresh branch in the gateway repo for Phase C:
   ```
   git -C repos/gateway checkout -b kadyapam/gateway-firestore-subscriptions
   ```

### Phase B — gateway subscription endpoint + SSE frame families

4. Add Firestore Admin server SDK to the gateway. Use whatever the
   Rust ecosystem offers (or a small embedded Python sidecar, or a
   gRPC bridge — pick the lowest-friction option; record the
   chosen approach in the result with rationale).
   - The service account credential lives **outside this repo**.
     Reference it by env var, e.g.
     `GATEWAY_FIRESTORE_CREDENTIALS_PATH` pointing at a path
     inside the gateway pod. **Never commit a real credential
     under ai-meta.** Provision via a Kubernetes Secret in a
     follow-up runbook entry.
5. Add `POST /api/subscriptions/firestore` route. Request body:
   ```json
   {
     "path": "chat_threads/<thread_id>/calendar_events",
     "scope": "owner"
   }
   ```
   Response:
   ```json
   {
     "subscription_id": "<uuid>",
     "client_id": "<existing-sse-client-id>"
   }
   ```
   Authorization: the session token's tenant + user_id must
   permit reading the requested path. Concrete check: the path
   must start with `chat_threads/<thread_id>/...` where
   `thread_id` is reachable to the user (look up in the same
   place the playbook executor checks thread ownership — likely
   the auth.sessions / auth.users tables).
6. Add `DELETE /api/subscriptions/{subscription_id}`. Cancels
   the server-side `onSnapshot` listener and removes the
   subscription state from `ConnectionHub`.
7. Server-side listener:
   - On `POST`, the gateway attaches a Firestore Admin
     `onSnapshot` (or equivalent) for the document collection
     scoped by the request.
   - Each snapshot callback turns into a `subscription/event`
     SSE frame keyed on `subscription_id` and forwarded via
     `ConnectionHub::send_to_client`. Payload:
     ```json
     {
       "subscription_id": "<uuid>",
       "doc_id": "<firestore_doc_id>",
       "data": { ... },
       "op": "added | modified | removed"
     }
     ```
8. Add a `playbook/state` SSE frame family:
   - Existing `playbook/result` stays as the final result payload
     channel.
   - The gateway subscribes (or otherwise observes) the
     NATS subject `playbooks.executions.<execution_id>.*` (or
     whatever the noetl-server emits — the gateway env shows
     `NATS_UPDATES_SUBJECT_PREFIX=playbooks.executions.`) and
     re-emits relevant state-change events over SSE as:
     ```json
     {
       "execution_id": "...",
       "event_type": "step.exit | playbook.completed | playbook.failed",
       "step_name": "...",
       "status": "...",
       "at": "<iso8601>"
     }
     ```
   - The SPA opts in to these by subscribing on a per-execution
     basis (either filter client-side, or add a subscribe
     request to the gateway that scopes the stream).
9. Tests in the gateway repo:
   - Unit: `POST /api/subscriptions/firestore` path-scope
     validation rejects out-of-tenant paths.
   - Integration: a mock SSE client receives `subscription/event`
     frames when the underlying collection changes, and
     `playbook/state` frames when a fake NATS frame is published
     on the `playbooks.executions.*` subject.

10. Commit gateway changes:
    ```
    git -C repos/gateway add -A
    git -C repos/gateway commit -m "feat(sse): firestore subscriptions + playbook/state lifecycle frames"
    git -C repos/gateway push -u origin kadyapam/gateway-firestore-subscriptions
    ```
11. Open the gateway PR with `gh pr create --repo noetl/gateway`.
    PR body must explain:
    - Why this change is needed (link the ai-meta decision doc +
      this thread's round-01-result).
    - The two new SSE frame families and their schemas.
    - The Firestore credential management contract
      (env var path; runbook entry pending).
    - That the SPA PR is on `noetl/travel#49` and will be
      extended with the consumer-side migration in this same
      round.

### Phase C — SPA migration

12. Continue on `kadyapam/travel-polling-timeout-stopgap`
    (already open as PR #49). Do not branch off; extend the
    existing PR with the migration so reviewers see the
    stopgap and the durable fix together.

13. Add `repos/travel/src/api/gatewaySubscriptions.ts`:
    - Function `subscribeToCollection(path, onItems, options)`
      that:
      - Calls `POST {{ gatewayBase }}/api/subscriptions/firestore`
        with the path and session token.
      - Wires the SSE `subscription/event` handler to coalesce
        snapshot ops into the `DocumentData[]` shape callers
        expect.
      - Returns an unsubscribe function that calls
        `DELETE /api/subscriptions/{subscription_id}`.
    - Function `subscribeToCalendarEvents(path, onItems)` —
      same as above but applies the sort/normalization currently
      done in `listenToCalendarEvents`.

14. Replace `repos/travel/src/api/firestoreClient.ts`:
    - Delete the file, OR leave it as a thin shim that re-exports
      `subscribeToCollection` / `subscribeToCalendarEvents` from
      `gatewaySubscriptions.ts` (whichever is cleaner — codex
      decides).
    - Update `repos/travel/src/components/widgets/CalendarView.tsx:25`
      and `89` to import from `gatewaySubscriptions.ts`.

15. Remove the `firebase` dependency:
    - `npm uninstall firebase`
    - Delete `VITE_FIREBASE_API_KEY`, `VITE_FIREBASE_AUTH_DOMAIN`,
      `VITE_FIREBASE_PROJECT_ID` from
      `repos/travel/.env.example`.
    - Delete the corresponding env injection in `Dockerfile`,
      `nginx.conf`, Cloudflare Pages config, or wherever those
      vars were wired (grep for `VITE_FIREBASE_` across the
      repo and any deploy config under `repos/travel/.github`
      or related).
    - Run `npm run build` and grep `dist/` for `firebase` —
      should return no matches. Report the bundle-size delta
      (`du -sh dist/` before and after).

16. Replace the polling loop:
    - In `repos/travel/src/api/noetlClient.ts`:
      - Add a function that subscribes the SPA to
        `playbook/state` frames (similar in shape to
        `playbook/result` handling). Resolves the promise on
        `playbook.completed` / `playbook.failed`.
      - Either remove `CALLBACK_GRACE_MS` (no longer needed
        since the lifecycle stream is authoritative) or convert
        it to a connection-startup grace only and rename it.
    - In `repos/travel/src/components/shell/ChatThread.tsx`:
      - Replace the 200-attempt polling loop in
        `waitForExecution` with subscription-based completion.
      - Keep one fallback path: if the gateway subscription
        emits an error or the SSE connection is lost for
        > N seconds, fall through to a single `getExecution`
        call (not a loop). If even that fails, surface the
        error as before.
    - Remove the `Execution {id} did not complete in time`
      error string (since the timeout path no longer exists in
      the happy case).

17. Tests in the SPA:
    - Add Vitest coverage for `gatewaySubscriptions.ts` using a
      mock SSE server (the existing test harness should have
      patterns to follow — survey first).
    - Add coverage for the new subscription-based
      `waitForExecution`.
    - Re-run `npm test`, `npm run type-check`, `npm run lint`.

18. Commit SPA changes on top of the existing PR branch:
    ```
    git -C repos/travel add -A
    git -C repos/travel commit -m "feat(sse): gateway-backed subscriptions; remove direct firebase access"
    git -C repos/travel push origin kadyapam/travel-polling-timeout-stopgap
    ```

    Update the PR description (use `gh pr edit`) to cover both
    the stopgap commit AND the Phase C migration. Reference the
    gateway PR. Re-request review.

### Phase D — write result

19. Write `round-02-result.md` with sections:
    ```
    ## Phase A — sync
    ## Phase B — gateway subscription endpoint
    ## Phase C — SPA migration
    ## Bundle / dependency delta
    ## Issues observed
    ## Manual escalation needed
    ```
    Include:
    - Submodule SHAs before and after.
    - Both PR URLs (gateway + travel).
    - The chosen Firestore Admin SDK approach and rationale.
    - Bundle size before / after `firebase` removal.
    - Test outputs (`npm test`, gateway `cargo test`).
    - Any auth/RBAC decisions taken (path-scope rule for
      subscriptions).
    - The credential provisioning steps a human needs to run
      (kubectl create secret, etc.). DO NOT INCLUDE THE
      CREDENTIAL ITSELF.

20. Commit + push the result file in `ai-meta`.

## Hard rules for this thread

- **Do not merge any PR.** Open both, link both, stop.
- **Do not commit or include any Firestore service-account JSON
  or Firebase API key under `ai-meta`.** This repo is public.
  If you need to demonstrate the credential format, use the
  literal placeholder `<service-account-json>` and explain
  how the human provisions the real one via
  `kubectl create secret`.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- If the Firestore Admin SDK has no acceptable Rust binding, you
  may use a thin Go or Python sidecar process invoked from the
  gateway — but flag this choice prominently in the gateway PR
  body so reviewers can weigh it. Do not silently introduce a
  new language to the gateway runtime.
- Phase C tests must run against a mocked SSE server, not the
  live gateway pod.

## What success looks like

- Gateway PR open with new SSE families and the subscription
  endpoint; tests green.
- Travel PR open (extends #49) removing `firebase` from
  `package.json`, removing the polling loop, switching
  `CalendarView` to gateway subscriptions; tests green; bundle
  no longer contains Firebase artifacts.
- `round-02-result.md` written, committed, pushed.
- No real credentials anywhere in either repo.

## Out of scope (for separate handoffs)

- Itinerary-planner playbook step consolidation.
- noetl-server `/api/executions?limit=N` stale-status bug.
- Platform-level event batching / inline child execution.
- KEDA / Helm / GKE infra changes.
