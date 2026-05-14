# Travel callback timeout poll fallback shipped

Date: 2026-05-13 22:33 PDT

Travel/Muno users were still hitting `Playbook callback timed out` while the
backend execution had actually started and sometimes reached terminal state with
useful payloads. The specific observed execution (`626368396275221407`) ran
through Duffel and the itinerary final-result path, but the browser waited on the
gateway SSE callback channel and did not recover cleanly when that callback was
missing or late.

Fix shipped in `repos/travel` PR #35:

- Treat the gateway callback as a short grace path. After 8 seconds without a
  callback, return the GraphQL execution id to the UI so the existing execution
  polling path takes over.
- If the SSE callback channel cannot connect, continue to GraphQL execution
  instead of blocking the turn up front.
- Resolve failed callback frames into execution metadata instead of throwing
  immediately, so the UI can poll and surface any final payload or concrete
  backend error.
- When a terminal failed/error/cancelled execution still carries widget, slot, or
  bot-message payload, render it instead of discarding it behind a generic error.
- The Cancel button now sends a best-effort NoETL execution cancel request once
  an execution id is known, then immediately unblocks the browser.

Validation:

- `npm run build` passed locally in `repos/travel`.
- `npm test -- --run` passed locally: 9 files, 19 tests.
- GitHub `Build and verify` passed on PR #35.
- Cloudflare Pages preview passed on PR #35.
- PR #35 was squash-merged to `noetl/travel@8659df3`.
- Main Cloudflare Pages deploy passed for run `25843659580`.

Design lesson:

For browser surfaces, a gateway callback should be an optimization, not the only
completion path. If GraphQL returns an execution id, the UI must be able to poll
status and render the execution result even when SSE delivery is delayed,
missing, or disconnected.
