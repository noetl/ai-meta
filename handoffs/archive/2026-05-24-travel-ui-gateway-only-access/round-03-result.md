---
thread: 2026-05-24-travel-ui-gateway-only-access
round: 3
from: codex
to: claude
created: 2026-05-24T17:43:53Z
in_reply_to: round-03-prompt.md
status: complete
---

# Travel UI gateway-only subscription work

## Phase A — sync

Read `handoffs/README.md`, `agents/rules/handoffs.md`, and
`agents/rules/writing-style.md` before work. The wait phrase
`proceed with gateway subscription work` was present in chat.

Synced `repos/travel`, `repos/gateway`, and `repos/ops` with
`origin/main`. Starting heads:

- `repos/travel`: `90d4048 fix(ui): extend playbook callback and polling windows (#49)`
- `repos/gateway`: `c410c14 chore(release): version 2.10.1 [skip ci]`
- `repos/ops`: `edff77f hardening: dev-playbook kind-only guard + chart KEDA template defensive defaults (#117)`

Opened fresh branches:

- `repos/gateway`: `kadyapam/gateway-firestore-subscriptions`
- `repos/travel`: `kadyapam/travel-gateway-subscriptions`

I did not revive `kadyapam/travel-polling-timeout-stopgap`.

## Phase B — gateway subscription endpoint

Gateway branch commit:

- `e7b76ef feat(sse): firestore subscriptions + playbook/state lifecycle frames`
- PR: https://github.com/noetl/gateway/pull/11

Implemented:

- `POST /api/subscriptions/firestore`
- `DELETE /api/subscriptions/{subscription_id}`
- `subscription/event` SSE frame family
- `playbook/state` SSE frame family sourced from NATS subjects under
  `playbooks.executions.`
- `GATEWAY_FIRESTORE_CREDENTIALS_PATH`, `GATEWAY_FIRESTORE_PROJECT_ID`, and
  `GATEWAY_FIRESTORE_LISTENER_CMD` config
- Runtime packaging for a Python Firestore listener sidecar

Chosen Firestore SDK approach: thin Python sidecar. The Rust gateway keeps
authentication, path checks, subscription state, and SSE routing. The sidecar
uses `google-cloud-firestore` to watch the collection and streams JSON lines to
the gateway. I chose this because the gateway had no Firestore code and a Rust
Admin/watch binding was not a low-risk addition for this round.

Path-scope predicate implemented:

- authenticated session required by gateway middleware
- `scope` must be `owner`
- path must match `chat_threads/<thread_id>/trip/current/events`
- `<thread_id>` must contain only ASCII letters, numbers, `.`, `_`, or `-`
- subscription binds to the caller's connected SSE `client_id` and session token

Validation:

- `cargo test`: passed. `6 passed; 0 failed`.

## Phase C — SPA migration

Travel branch commit:

- `97e2950 feat(sse): gateway-backed subscriptions; remove direct firebase access`
- PR: https://github.com/noetl/travel/pull/50

Implemented:

- Removed `src/api/firestoreClient.ts`.
- Added `src/api/gatewaySubscriptions.ts`.
- Switched `CalendarView.tsx` live mode to `subscribeToCalendarEvents`.
- Removed `firebase` from `package.json` and `package-lock.json`.
- Removed `VITE_FIREBASE_*` references from app docs/config.
- Added `playbook/state` SSE handling in `src/api/noetlClient.ts`.
- Replaced the 200-attempt `ChatThread.waitForExecution` loop with
  lifecycle-stream completion plus one safety-net `getExecution` call if the
  lifecycle stream disconnects.
- Removed the `Execution {id} did not complete in time` error path.

Validation:

- `npm test`: passed. `10 passed (10)`, `21 passed (21)`.
- `npm run type-check`: passed. `Generated src/contracts/widgets.ts from 25 schemas`.
- `npm run lint`: passed.
- `npm run build`: passed.
- `grep -r firebase dist/`: zero matches.

## Bundle / dependency delta

- Before: existing `dist/` was `2.0M`.
- After `npm run build`: `dist/` is `1.9M`.
- `firebase` and `@firebase/*` entries are absent from `package.json` and
  `package-lock.json`.

Submodule pointer state:

- ai-meta tracked `repos/gateway` before/after: `c410c14`; unmerged PR head is
  `e7b76ef`.
- ai-meta tracked `repos/travel` before/after: `90d4048`; unmerged PR head is
  `97e2950`.
- ai-meta tracked `repos/ops` before/after: `edff77f`.

I switched the local `repos/gateway` and `repos/travel` worktrees back to
`main` after pushing the PR branches so ai-meta does not record unmerged
submodule pointers.

## Issues observed

- The gateway has no existing thread-ownership lookup to reuse. The PR enforces
  a strict path shape and binds subscriptions to the authenticated session and
  SSE client, but reviewers should decide whether to add a stronger
  `thread_id` ownership check before production rollout.
- The gateway tests cover path rejection and mocked SSE delivery through the
  connection hub. They do not exercise a live Firestore watch; that still needs
  a deployment or integration environment with a mounted service-account file.
- Gateway PR `#11` introduces Python in the runtime image for the Firestore
  sidecar. This is called out in the PR body for reviewer approval.

## Manual escalation needed

Operator credential provisioning, with no credential content committed:

```bash
kubectl create secret generic gateway-firestore-credentials \
  --from-file=service-account.json=<service-account-json> \
  -n <gateway-namespace>
```

Set `GATEWAY_FIRESTORE_PROJECT_ID` or `GOOGLE_CLOUD_PROJECT` for the gateway
deployment. Reviewers should also confirm the namespace, secret name, and
whether the `thread_id` ownership predicate needs a NoETL-backed lookup before
the gateway PR is marked ready.
