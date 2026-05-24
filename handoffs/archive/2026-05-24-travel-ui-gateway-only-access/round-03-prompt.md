---
thread: 2026-05-24-travel-ui-gateway-only-access
round: 3
from: claude
to: codex
created: 2026-05-24T17:55:00Z
status: open
expects_result_at: round-03-result.md
---

# Phase C — gateway subscription endpoint + remove Firebase SDK from SPA (post-#49 merge)

> **Predecessors in this thread:**
> - `round-01-prompt.md` / `round-01-result.md`: survey + design +
>   Phase B stopgap on a feature branch.
> - `round-02-prompt.md` / `round-02-result.md`: Phase C dispatch
>   that was superseded before execution because the user merged
>   `noetl/travel#49` (Phase B stopgap) out-of-band. The Phase B
>   patch is now in `repos/travel:main` at commit
>   `90d4048 fix(ui): extend playbook callback and polling windows (#49)`.

You are operating in `/Volumes/X10/projects/noetl/ai-meta`. Read
`handoffs/README.md`, `agents/rules/handoffs.md`, and
`agents/rules/writing-style.md` (no "canonical" in prose) first.

## Wait phrase

***proceed with gateway subscription work*** — given by the user
in chat. Phase C is authorized to run.

## Context recap (from round 01)

- SPA reads Firestore directly via `firebase/firestore`
  `onSnapshot` in `repos/travel/src/api/firestoreClient.ts`, used
  by `CalendarView.tsx:89`.
- Gateway repo `repos/gateway` at `c410c14` (v2.10.1) emits
  `playbook/result`, `playbook/progress`, `ping`, and init
  `message` frames over SSE at `GET /events`.
- No gateway-side Firestore code today. The Firestore MCP at
  `repos/ops/automation/agents/mcp/firestore.yaml` writes via
  REST and does not emit NATS events.
- Recommended design (from round 01): gateway adds Firestore
  Admin server-side listeners + `POST /api/subscriptions/firestore`
  + new SSE frame families `subscription/event` and
  `playbook/state`.

## What changed since round 01

- `noetl/travel#49` merged. `repos/travel:main` now includes:
  - `waitForExecution` polling ceiling 90s → 5min (200 attempts).
  - `CALLBACK_GRACE_MS` 8s → 30s with stopgap comment.
- ai-meta pointer for `repos/travel` updated to the post-merge SHA
  in the same commit that opens this round.

## What this round delivers

1. Gateway-side subscription endpoint at
   `POST /api/subscriptions/firestore` (and `DELETE
   /api/subscriptions/{id}`), backed by Firestore Admin
   server-side listeners scoped to the authenticated session.
2. New SSE frame families on the existing `/events` channel:
   - `subscription/event` for Firestore live updates.
   - `playbook/state` for execution lifecycle
     (`step.exit`, `playbook.completed`, `playbook.failed`).
3. SPA migration off `firebase/firestore`:
   - Replace `firestoreClient.ts` with `gatewaySubscriptions.ts`
     using SSE.
   - Drop `firebase` from `package.json`.
   - Drop `VITE_FIREBASE_*` from `.env.example` and any build
     config.
4. SPA migration off the `waitForExecution` polling loop:
   - Subscribe to `playbook/state` for the active execution.
   - Keep a single safety-net `getExecution` call on
     subscription error.
5. Two PRs (do not merge): one on `repos/gateway` (new branch),
   one on `repos/travel` (new branch — **do not extend the
   already-merged stopgap branch**).
6. Result file at
   `handoffs/active/2026-05-24-travel-ui-gateway-only-access/round-03-result.md`.

## Phases

### Phase A — confirm starting state + open branches

1. Sync submodules to current main:
   ```
   git -C repos/travel fetch origin && git -C repos/travel checkout main && git -C repos/travel pull --ff-only origin main
   git -C repos/gateway fetch origin && git -C repos/gateway checkout main && git -C repos/gateway pull --ff-only origin main
   git -C repos/ops fetch origin && git -C repos/ops checkout main && git -C repos/ops pull --ff-only origin main
   ```
2. Confirm `repos/travel:main` head includes the merged stopgap:
   ```
   git -C repos/travel log --oneline -3
   # expect: 90d4048 fix(ui): extend playbook callback and polling windows (#49)
   ```
3. Open fresh branches:
   ```
   git -C repos/gateway checkout -b kadyapam/gateway-firestore-subscriptions
   git -C repos/travel  checkout -b kadyapam/travel-gateway-subscriptions
   ```

### Phase B — gateway subscription endpoint + SSE frame families

4. Pick the Firestore Admin SDK approach for the gateway:
   - **Preferred:** native Rust Firestore Admin SDK if one is
     viable.
   - **Acceptable:** a thin Go or Python sidecar process invoked
     from the gateway via local IPC or gRPC.
   - **Not acceptable silently:** introducing a new language
     to the gateway runtime without flagging it in the PR body.
   The credential lives **outside ai-meta**. Reference by env var
   `GATEWAY_FIRESTORE_CREDENTIALS_PATH`. Document the
   provisioning runbook step in the PR body
   (`kubectl create secret`).

5. Add `POST /api/subscriptions/firestore`. Body:
   ```json
   {
     "path": "chat_threads/<thread_id>/calendar_events",
     "scope": "owner"
   }
   ```
   Response:
   ```json
   { "subscription_id": "<uuid>", "client_id": "<existing-sse-client-id>" }
   ```
   Authorization: the session token's tenant + user_id must
   permit reading the requested path. Concrete check: the path
   must start with `chat_threads/<thread_id>/...` where
   `thread_id` is reachable to the user (re-use whatever thread-
   ownership check the playbook executor already does — likely
   `auth.sessions` / `auth.users` lookup).

6. Add `DELETE /api/subscriptions/{subscription_id}` that
   cancels the server-side listener and removes subscription
   state from `ConnectionHub`.

7. Server-side listener emits `subscription/event` SSE frames via
   `ConnectionHub::send_to_client`:
   ```json
   {
     "subscription_id": "<uuid>",
     "doc_id": "<firestore_doc_id>",
     "data": { ... },
     "op": "added | modified | removed"
   }
   ```

8. Add a `playbook/state` SSE frame family.
   - Existing `playbook/result` stays as the final result payload
     channel; do not change its shape.
   - The gateway subscribes to the NATS subject prefix
     `playbooks.executions.<execution_id>.*`
     (`NATS_UPDATES_SUBJECT_PREFIX=playbooks.executions.` in the
     gateway env) and re-emits relevant state-change events as:
     ```json
     {
       "execution_id": "...",
       "event_type": "step.exit | playbook.completed | playbook.failed",
       "step_name": "...",
       "status": "...",
       "at": "<iso8601>"
     }
     ```
   - The SPA opts in per-execution (filter client-side, or add
     a subscribe request that scopes the stream — codex picks
     and records the choice).

9. Tests on the gateway side:
   - Unit: `POST /api/subscriptions/firestore` rejects
     out-of-tenant paths.
   - Integration: a mock SSE client receives
     `subscription/event` frames when the underlying collection
     changes, and `playbook/state` frames when a fake
     `playbooks.executions.*` NATS frame is published.

10. Commit gateway changes:
    ```
    git -C repos/gateway add -A
    git -C repos/gateway commit -m "feat(sse): firestore subscriptions + playbook/state lifecycle frames"
    git -C repos/gateway push -u origin kadyapam/gateway-firestore-subscriptions
    ```
11. Open the gateway PR with `gh pr create --repo noetl/gateway`.
    Body must cover:
    - Why (link the ai-meta decision doc + this thread's
      round-01-result).
    - The two new SSE frame families with their JSON schemas.
    - The Firestore credential management contract (env var
      path; runbook entry pending).
    - The chosen Firestore SDK approach and rationale (especially
      if a sidecar process was introduced).
    - Reference to the travel SPA PR opened in Phase C.

### Phase C — SPA migration (fresh branch, fresh PR)

12. Work on the fresh branch
    `kadyapam/travel-gateway-subscriptions` you opened in Phase A
    step 3. **Do not revive the merged `kadyapam/travel-polling-
    timeout-stopgap` branch.**

13. Add `repos/travel/src/api/gatewaySubscriptions.ts`:
    - `subscribeToCollection(path, onItems, options)`:
      - Calls `POST {gatewayBase}/api/subscriptions/firestore`
        with the path and session token.
      - Wires the SSE `subscription/event` handler to coalesce
        snapshot ops into the `DocumentData[]` shape callers
        expect.
      - Returns an unsubscribe function that calls
        `DELETE /api/subscriptions/{subscription_id}`.
    - `subscribeToCalendarEvents(path, onItems)` — same with
      the sort/normalization that `listenToCalendarEvents`
      currently applies.

14. Replace `repos/travel/src/api/firestoreClient.ts`:
    - Delete the file, OR leave it as a thin re-export shim
      pointing at `gatewaySubscriptions.ts` (codex decides).
    - Update `repos/travel/src/components/widgets/CalendarView.tsx`
      lines 25 and 89 to import from `gatewaySubscriptions.ts`.

15. Remove the `firebase` dependency:
    - `npm uninstall firebase`.
    - Delete `VITE_FIREBASE_API_KEY`, `VITE_FIREBASE_AUTH_DOMAIN`,
      `VITE_FIREBASE_PROJECT_ID` from `repos/travel/.env.example`.
    - Grep for `VITE_FIREBASE_` across the repo (Dockerfile,
      nginx.conf, `.github/workflows/`, Cloudflare Pages
      config) and delete every reference.
    - `npm run build` then `grep -r firebase dist/`. Expect zero
      matches. Report the bundle-size delta (`du -sh dist/`
      before and after).

16. Replace the polling loop:
    - In `repos/travel/src/api/noetlClient.ts`:
      - Add a function that subscribes the SPA to
        `playbook/state` frames (similar in shape to
        `playbook/result` handling). Resolve the promise on
        `playbook.completed` / `playbook.failed`.
      - Either remove `CALLBACK_GRACE_MS` (lifecycle stream is
        authoritative now) or convert it to a connection-startup
        grace only and rename it.
    - In `repos/travel/src/components/shell/ChatThread.tsx`:
      - Replace the 200-attempt polling loop with subscription-
        based completion.
      - Keep one fallback: if the gateway subscription emits an
        error or the SSE connection drops for > N seconds, fall
        through to a single `getExecution` call (not a loop). If
        even that fails, surface the error as before.
      - Remove the `Execution {id} did not complete in time`
        error string — the timeout path is gone in the happy
        case.

17. Tests on the SPA side:
    - Add Vitest coverage for `gatewaySubscriptions.ts` against a
      mock SSE server. Survey existing mock-SSE patterns in
      `repos/travel` first.
    - Add coverage for the subscription-based
      `waitForExecution`.
    - Re-run `npm test`, `npm run type-check`, `npm run lint`.

18. Commit SPA changes:
    ```
    git -C repos/travel add -A
    git -C repos/travel commit -m "feat(sse): gateway-backed subscriptions; remove direct firebase access"
    git -C repos/travel push -u origin kadyapam/travel-gateway-subscriptions
    ```
19. Open the travel PR with `gh pr create --repo noetl/travel`.
    Body must cover:
    - Why (post-#49 follow-up; link round-01-result).
    - What changes in `firestoreClient.ts` →
      `gatewaySubscriptions.ts`.
    - Removal of `firebase` from `package.json` and bundle-
      size delta.
    - Removal of `VITE_FIREBASE_*` env vars.
    - Reference the gateway PR opened in Phase B.

### Phase D — write result

20. Write `round-03-result.md` with sections:
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
    - Path-scope rule for subscriptions (exact predicate
      implemented).
    - Credential provisioning steps a human needs to run
      (`kubectl create secret`). **DO NOT INCLUDE THE
      CREDENTIAL CONTENT.**

21. Commit + push the result in `ai-meta`.

## Hard rules for this thread

- **Do not merge any PR.** Open both, link both, stop.
- **Do not commit or include any Firestore service-account JSON
  or Firebase API key under `ai-meta`.** This repo is public.
  If you need to demonstrate the credential format, use the
  literal placeholder `<service-account-json>` and explain how
  the human provisions the real one via `kubectl create secret`.
- **Do not force-push.**
- **Do not run `noetl_gke_fresh_stack.yaml --set action=provision`.**
- **No "canonical"** in any commit message, PR body, doc, or
  prose. See `agents/rules/writing-style.md`.
- If the Firestore Admin SDK has no acceptable Rust binding, you
  may use a thin Go or Python sidecar — but flag the choice
  prominently in the gateway PR body so reviewers can weigh it.
  Do not silently introduce a new language to the gateway
  runtime.
- Phase C tests must run against a mocked SSE server, not the
  live gateway pod.
- **Do not revive `kadyapam/travel-polling-timeout-stopgap` in
  `repos/travel`.** It is merged. Work on the fresh
  `kadyapam/travel-gateway-subscriptions` branch.

## What success looks like

- Gateway PR open on `noetl/gateway` with new SSE families and
  the subscription endpoint; tests green.
- Travel PR open on `noetl/travel` with `firebase` removed from
  `package.json`, polling loop removed, `CalendarView` switched
  to gateway subscriptions; tests green; bundle no longer
  contains Firebase artifacts.
- `round-03-result.md` written, committed, pushed.
- Zero credentials anywhere in either repo.

## Out of scope (separate handoffs)

- Itinerary-planner playbook step consolidation.
- noetl-server `/api/executions?limit=N` stale-status bug.
- Platform-level event batching / inline child execution.
- KEDA / Helm / GKE infra changes.
