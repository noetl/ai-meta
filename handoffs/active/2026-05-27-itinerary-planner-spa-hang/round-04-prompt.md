---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 4
from: claude
to: claude
created: 2026-05-27T16:45:00Z
status: open
expects_result_at: round-04-result.md
wait_phrase: "proceed with gateway callback state fix"
---

# Round 04 — Callback removes routing entry before NATS lifecycle event reaches gateway

> **Predecessors in this thread:**
> - `round-01-result.md` (NATS subject mismatch + parser shape) — fixed
>   via `noetl/gateway#12` + `noetl/ops#120`.
> - `round-02-result.md` (outbox publishes arrow-feather, gateway
>   expects JSON) — fixed via `noetl/noetl#620`.
> - `round-03-result.md` (gateway tokio task silently panicked,
>   subscription dead despite "Subscribing" log) — fixed via
>   `noetl/gateway#13` with per-message INFO log + panic surfacing.

After rounds 01–03 the gateway is healthy, the subscription is
alive, the broker is delivering messages, and the worker callback
delivers `playbook/result`.  But the SPA still hangs at
`Muno is planning…` because the SPA waits on a `playbook/state`
notification — not `playbook/result` — to exit the planning state.

## The actual bug (verified from production)

The SPA's `waitForExecutionCompletion(executionId)` resolves on a
`playbook/state` notification whose `event_type` is
`playbook.completed` / `playbook.failed` and whose `execution_id`
matches.  See
`repos/travel/src/api/noetlClient.ts:129-149`.

Two pathways feed that signal:

1. The NATS lifecycle listener in
   `repos/gateway/src/playbook_state.rs`, which iterates
   `request_store.get_by_execution(&execution_id)` on every received
   message that matches `FORWARDED_EVENT_TYPES`.
2. The worker HTTP callback POST to `/api/internal/callback`, which
   currently emits **only** `playbook/result` and removes the
   pending request entry at the end of the handler
   (`repos/gateway/src/sse.rs:381`).

Timing on production execution `636124154944553085` (parent
orchestrator for a "trip to Paris" chat turn):

```
16:25:22.695  HTTP callback delivered → request_store.remove(rid)
16:25:22.970  NATS workflow.completed payload received
16:25:22.979  NATS playbook.completed payload received
```

By `.970` the routing entry was already removed.  The NATS listener
called `get_by_execution("636124154944553085")` and got an empty
list — no client to forward to.  No `playbook/state` notification
ever reached the SPA.

Verified independently from the outbox table:

```
outbox_id  event_id              event_type             status
1572       636124275027476815    workflow.completed     PUBLISHED
1573       636124275195248976    playbook.completed     PUBLISHED
1574       636124275413352785    batch.completed        PUBLISHED
```

All events landed in JetStream.  Gateway received them — confirmed
via the round-03 instrumentation — but had no routing entry to
deliver to.

## What Round 04 delivers

The smallest change that makes the SPA exit the planning state on
every chat turn, without coupling the SPA to a single event source
and without changing the noetl publisher or NATS subject layout.

**Fix shape (Option A — implemented):**

In `repos/gateway/src/sse.rs::callback_handler`, when the callback
fires, synthesize a `playbook/state` notification with the same
`execution_id` and the completion status mapped from
`callback.status` / `callback.error`.  Send the state notification
first so the SPA's lifecycle map resolves before `playbook/result`
attaches the widget envelope.  A second delivery from the NATS
listener (when it eventually arrives) is a no-op — the SPA's
`handlePlaybookState` early-returns when `pending` is missing.

## Phases

### Phase A — read-only audit

1. Re-read `round-03-result.md` end-to-end.
2. Pull gateway logs since the last `gateway:instrumented-…` deploy,
   confirm `Received execution lifecycle NATS message` lines for
   `playbook.completed` payloads (Round 03 instrumentation).
3. Query the outbox for the latest hung execution; confirm the
   `playbook.completed` row is `PUBLISHED`.
4. Read the SPA's `noetlClient.ts` `handlePlaybookState` +
   `waitForExecutionCompletion` to confirm the resolution shape.

### Phase B — code change

5. Branch `kadyapam/callback-emits-playbook-state` off
   `repos/gateway` `main`.
6. Edit `repos/gateway/src/sse.rs::callback_handler` to:
   - Capture the resolved `execution_id` once.
   - Build a `playbook/state` JSON-RPC notification with that
     `execution_id`, derived `event_type` (`playbook.completed` or
     `playbook.failed`), status (`completed` / `failed`), and
     current UTC `at`.
   - Send the state notification BEFORE the existing
     `playbook/result` send, log success at INFO with a
     grep-able fingerprint.
   - Keep the existing `playbook/result` send + the
     `request_store.remove(...)` cleanup unchanged.
7. `cargo build && cargo test`.

### Phase C — open draft PR

8. Push branch, open draft PR on `noetl/gateway` titled
   "fix(sse): emit synthetic playbook/state from callback handler".
   Body should cite the production timing evidence above and the
   diagnostic chain from rounds 01–04.

### Phase D — live re-deploy (GATED)

> ***Run only after explicit human go-ahead. Wait phrase: `proceed
> with gateway callback state fix`.***

9. After PR merges:
   - Rebuild gateway image off `main`.
   - `helm upgrade noetl-gateway` with the new image tag.
   - Have the user trigger one chat turn on `travel.mestumre.dev`.
   - Pull gateway logs since the deploy and grep for
     `Synthetic playbook/state delivered:` — must appear for the
     turn's execution_id.
   - Confirm the SPA exits the `"Muno is planning…"` state.

## Hard rules

- Do NOT modify the cluster during Phases A–C.
- Do NOT push to `main` on any repo.
- Do NOT merge any PR yourself.
- Phase D is gated on the wait phrase
  `proceed with gateway callback state fix`.
- No "canonical" in any prose or commit message.
- Per-message INFO logging only at the callback boundary (low
  frequency, bounded by playbook lifecycle).  No INFO on the SSE
  send path itself.

## What success looks like

- A draft PR on `noetl/gateway` with the synthetic state
  notification + a clear evidence-backed body.
- After deploy, a single chat turn produces both a
  `Synthetic playbook/state delivered:` log line and the SPA
  exits the planning state.
- The NATS lifecycle path remains as the secondary delivery
  channel (no-op on duplicate but still functional for
  callback-less execution flows).

## FINAL REPORT

Always emit, even on early STOP.  Frontmatter:

```yaml
---
thread: 2026-05-27-itinerary-planner-spa-hang
round: 4
from: claude
to: claude
created: <ISO8601 UTC>
in_reply_to: round-04-prompt.md
status: complete | partial | blocked
---
```
